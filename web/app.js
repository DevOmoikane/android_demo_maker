/* Demo Maker Web Studio frontend. Vanilla JS, no dependencies. */
"use strict";

const TOKEN = location.pathname.split("/")[1];
const API = "/" + TOKEN;

const $ = (sel, root) => (root || document).querySelector(sel);
const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

const State = {
  settings: {},
  tools: {},
  darwin: true,
  devices: [],
  packagesBySerial: {},
  sayVoices: [],
  piperVoices: [],
  piperBinary: null,
  schema: null,
  defaultOrder: [],
  steps: [],
  stepsPath: "",
  recents: [],
  errors: [],
  dirty: false,
  pollTimer: null,
  pollOffset: 0,
  specLoaded: false,
  specOffset: 0,
  specTimer: null,
  specDoc: [],
  specSchema: null,
  specOrder: [],
  catalog: null,
};

/* The App tab has two identical device/app slots. Slot 1 is the main device and
   has always existed; slot 2 appears when "record a second device" is checked.
   Everything that used to hardcode #app-input and State.packages takes a slot
   number instead, so the two slots cannot drift apart. */
const SLOTS = {
  1: {device: "#device-select", app: "#app-input", sug: "#app-suggestions",
      filter: "#app-filter", act: "#activity-input", hint: "#apps-hint",
      appKey: "app_id", actKey: "activity", serialKey: "serial"},
  2: {device: "#device-select-2", app: "#app-input-2", sug: "#app-suggestions-2",
      filter: "#app-filter-2", act: "#activity-input-2", hint: "#apps-hint-2",
      appKey: "app_id_2", actKey: "activity_2", serialKey: "serial_2"},
};

/* Which document the Steps tree is currently editing:
   "demo" steps JSON, or one scenario entry of a spec-test file. */
const Editor = {mode: "demo", filePath: "", entryIndex: -1};

function activeSteps() {
  if (Editor.mode !== "scenario") return State.steps;
  const entry = State.specDoc[Editor.entryIndex];
  return entry && Array.isArray(entry.steps) ? entry.steps : [];
}

function schemaFor() {
  return Editor.mode === "scenario"
    ? (State.specSchema || State.schema)
    : State.schema;
}

/* ---------------------------------------------------------------- utils */

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else node.setAttribute(key, value);
    }
  }
  for (const child of children) {
    if (child === null || child === undefined) continue;
    node.append(child.nodeType ? child : document.createTextNode(child));
  }
  return node;
}

async function api(path, options) {
  const opts = Object.assign({headers: {}}, options || {});
  if (opts.body !== undefined && typeof opts.body !== "string") {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(opts.body);
  }
  const response = await fetch(API + path, opts);
  let data = {};
  try { data = await response.json(); } catch (e) { /* non-JSON body */ }
  if (!response.ok) {
    throw new Error(data.error || ("HTTP " + response.status));
  }
  return data;
}

function toast(message, kind) {
  const box = $("#toasts");
  const item = el("div", {class: "toast " + (kind || ""), text: message});
  box.append(item);
  setTimeout(() => item.remove(), kind === "error" ? 6500 : 3200);
}

function debounce(fn, ms) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

/* A settings PUT is a read-modify-write of the whole file server-side, so two
   in flight at once can each overwrite the other's key. Chaining them keeps the
   optimistic assign below and the promise above, and loses nothing. It matters
   here because one field already saves twice: picking or typing an app id saves
   it, then resolving the activity saves it again with the activity.

   The chain is bounded so one request the backend never answers cannot stall
   every save after it: the queue moves on when the request is given up on, and
   the save that was queued behind it goes out. */
const SETTINGS_PUT_TIMEOUT = 10000;
let settingsQueue = Promise.resolve();

function saveSettings(partial) {
  Object.assign(State.settings, partial);
  refreshCommandPreviewSoon();
  const put = settingsQueue.then(() => settingsPut(partial));
  settingsQueue = put.catch(() => {});
  return put.catch((err) => toast("settings not saved: " + err.message, "error"));
}

function settingsPut(partial) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SETTINGS_PUT_TIMEOUT);
  return api("/api/settings", {method: "PUT", body: partial,
                               signal: controller.signal})
    .catch((err) => {
      // abort() takes a reason only in newer browsers, so name the timeout here
      // rather than showing whatever the fetch happened to reject with
      if (controller.signal.aborted) {
        throw new Error("the studio backend did not answer");
      }
      throw err;
    })
    .finally(() => clearTimeout(timer));
}

/* ---------------------------------------------------------------- tabs */

$$(".tab").forEach((btn) => {
  btn.addEventListener("click", () => activateTab(btn.dataset.tab));
});

function activateTab(name) {
  $$(".tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === name));
  $$(".panel").forEach((p) => p.classList.toggle("active", p.id === "tab-" + name));
  if (name === "run") refreshCommandPreview();
  if (name === "app") loadDevices();
  if (name === "spec") ensureSpecLoaded();
}

/* ---------------------------------------------------------------- boot */

async function boot() {
  try {
    const state = await api("/api/state");
    State.settings = state.settings;
    State.tools = state.tools;
    State.darwin = state.darwin;
    $("#version-badge").textContent = "v" + state.version;
    bindAppTab();
    bindCompanionDevice();
    bindNarrationTab(state);
    bindOutputTab();
    bindRunTab();
    bindSpecTab();
    bindDialogs();
    await loadSchema();
    applyEngineVisibility();
    await loadVoices();
    loadCatalog(false);
    await loadDevices();
    if (state.steps_exists) await loadSteps(State.settings.steps_path);
    fillOutputTab();
    updateToolHints(state);
    setInterval(updateDeviceChipQuietly, 15000);
    updateDeviceChipQuietly();
    resumePollingIfRunning();
  } catch (err) {
    toast("failed to reach studio backend: " + err.message, "error");
  }
}

function updateToolHints(state) {
  const missing = [];
  for (const tool of ["adb", "jq", "ffmpeg"]) {
    if (!State.tools[tool]) missing.push(tool);
  }
  const hint = $("#adb-hint");
  if (missing.length) {
    hint.textContent = "missing tools: " + missing.join(", ") +
      ". Close the studio, run ./setup.sh, and reopen.";
    hint.style.color = "var(--err)";
  } else {
    hint.textContent = "";
  }
  $("#script-hint").textContent = State.tools.ffprobe
    ? "" : "ffprobe is missing: recording will fail until it is installed.";
}

/* ================================================================ APP TAB */

function bindAppTab() {
  $("#device-refresh").addEventListener("click", loadDevices);
  $("#device-select").addEventListener("change", async () => {
    const serial = $("#device-select").value;
    await saveSettings({serial});
    // re-derive the companion picker: the device just made the main one must
    // not stay sitting in the second slot
    if (State.settings.second_device) applyCompanionDevice();
    updateDeviceChip();
    if (serial) loadPackages(1);
  });
  $$('input[name="scope"]').forEach((radio) => {
    radio.checked = radio.value === (State.settings.scope || "user");
    radio.addEventListener("change", () => {
      if (radio.checked) {
        saveSettings({scope: radio.value});
        // scope filters both package lists, so both hints have to follow it
        loadPackages(1);
        if (State.settings.second_device) loadPackages(2);
      }
    });
  });
  $("#app-filter").addEventListener("input", debounce(() => renderAppOptions(1), 200));
  const appInput = $("#app-input");
  appInput.value = State.settings.app_id || "";
  appInput.addEventListener("change", () => {
    saveSettings({app_id: appInput.value.trim()});
    refreshCommandPreviewSoon();
  });
  appInput.addEventListener("focus", () => openAppSuggestions(1));
  appInput.addEventListener("input", () => renderAppSuggestions(1));
  bindAppInputKeys(1);
  document.addEventListener("click", (event) => {
    // One handler for both slots: a click only leaves a dropdown open when it
    // landed inside that slot's own input wrapper.
    for (const slot of [1, 2]) {
      if (!$(SLOTS[slot].sug).parentElement.contains(event.target)) {
        closeAppSuggestions(slot);
      }
    }
  });
  const actInput = $("#activity-input");
  actInput.value = State.settings.activity || "";
  actInput.addEventListener("change", () =>
    saveSettings({activity: actInput.value.trim()}));
  $("#app-resolve").addEventListener("click", () => resolveActivity(1));
  appInput.addEventListener("change", () => {
    if (appInput.value.includes(".")) resolveActivity(1);
  });
}

function bindCompanionDevice() {
  const toggle = $("#second-device-toggle");
  toggle.checked = !!State.settings.second_device;
  const appInput = $("#app-input-2");
  appInput.value = State.settings.app_id_2 || "";
  const actInput = $("#activity-input-2");
  actInput.value = State.settings.activity_2 || "";

  toggle.addEventListener("change", () => {
    saveSettings({second_device: toggle.checked});
    applyCompanionDevice();
    updateDeviceChip();
  });
  $("#device-select-2").addEventListener("change", async () => {
    const serial = $("#device-select-2").value;
    await saveSettings({serial_2: serial});
    updateDeviceChip();
    if (serial) loadPackages(2);
  });
  $("#app-filter-2").addEventListener("input", debounce(() => renderAppOptions(2), 200));
  appInput.addEventListener("change", () => {
    saveSettings({app_id_2: appInput.value.trim()});
    refreshCommandPreviewSoon();
  });
  appInput.addEventListener("focus", () => openAppSuggestions(2));
  appInput.addEventListener("input", () => renderAppSuggestions(2));
  bindAppInputKeys(2);
  $("#app-resolve-2").addEventListener("click", () => resolveActivity(2));
  appInput.addEventListener("change", () => {
    if (appInput.value.includes(".")) resolveActivity(2);
  });
  actInput.addEventListener("change", () =>
    saveSettings({activity_2: actInput.value.trim()}));

  applyCompanionDevice();
}

/* The keyboard contract of a package field, identical for both slots: arrows
   walk an open dropdown, Enter takes the highlighted package and a plain Enter
   falls through to the change handler, Escape dismisses, and ArrowDown on a
   closed dropdown opens it. Shared so slot 2 cannot drift from slot 1. */
function bindAppInputKeys(slot) {
  const box = $(SLOTS[slot].sug);
  $(SLOTS[slot].app).addEventListener("keydown", (event) => {
    if (!box.hidden) {
      const count = Suggest[slot].items.length;
      if (event.key === "ArrowDown" && count) {
        event.preventDefault();
        Suggest[slot].active = Math.min(Suggest[slot].active + 1, count - 1);
        highlightSuggestion(slot);
        return;
      }
      if (event.key === "ArrowUp" && count) {
        event.preventDefault();
        Suggest[slot].active = Math.max(Suggest[slot].active - 1, 0);
        highlightSuggestion(slot);
        return;
      }
      if (event.key === "Enter") {
        if (Suggest[slot].active >= 0) {
          event.preventDefault();
          pickApp(slot, Suggest[slot].items[Suggest[slot].active]);
        }
        return;  // plain Enter falls through to the change handler
      }
      if (event.key === "Escape") {
        closeAppSuggestions(slot);
        return;
      }
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      renderAppSuggestions(slot);
    }
  });
}

/* Shows or hides the companion block and refills its picker. loadDevices calls
   this as well, so the second picker is rebuilt whenever the device list
   changes rather than only when the box is ticked. */
function applyCompanionDevice() {
  const on = $("#second-device-toggle").checked;
  $("#second-device-block").hidden = !on;
  if (on) fillCompanionSelect();
  else closeAppSuggestions(2);
}

/* Focusing a package field opens its dropdown and closes the other slot's, so
   tabbing from one device's field to the other's never leaves two lists
   hanging open over the tab. */
function openAppSuggestions(slot) {
  for (const other of [1, 2]) {
    if (other !== slot) closeAppSuggestions(other);
  }
  renderAppSuggestions(slot);
}

/* The serial a slot is pointed at. The picker is the source of truth, because
   it can hold a derived default the settings do not: fillCompanionSelect
   suggests a second device without saving it, so before the user picks one,
   settings.serial_2 is still empty and anything reading only the settings would
   say "no device" about a picker visibly showing one. */
function serialForSlot(slot) {
  const sel = $(SLOTS[slot].device);
  return (sel && sel.value) || State.settings[SLOTS[slot].serialKey] || "";
}

function fillCompanionSelect() {
  const sel = $("#device-select-2");
  sel.innerHTML = "";
  if (!State.devices.length) {
    sel.append(el("option", {value: "", text: "no devices found"}));
  }
  for (const dev of State.devices) {
    const label = dev.model
      ? dev.serial + "  (" + dev.model + ", " + dev.state + ")"
      : dev.serial + "  (" + dev.state + ")";
    sel.append(el("option", {value: dev.serial, text: label}));
  }
  // Never default to the main device's serial: the driver rejects a second
  // device identical to the first, and the argv builder's own check turns that
  // into the Run tab's preview error instead of a recording that fails.
  const saved = State.settings.serial_2;
  const value = (saved && State.devices.some((d) => d.serial === saved))
    ? saved
    : (State.devices.find((d) => d.serial !== State.settings.serial) || {}).serial || "";
  // A select cannot show "nothing chosen" without an option to choose, so say
  // why it is empty rather than leaving a blank control with no explanation.
  if (!value && State.devices.length) {
    sel.append(el("option", {value: "", text: "no other device attached"}));
  }
  // The default is deliberately not saved: it is a suggestion, not a choice,
  // and it is re-derived from the device list on every scan and every reload.
  // serialForSlot reads it from here, so nothing waits on a write the server's
  // unsynchronized settings update could drop anyway.
  sel.value = value;
  if (value) loadPackages(2);
}

async function loadDevices() {
  const select = $("#device-select");
  try {
    const data = await api("/api/devices");
    State.devices = data.devices || [];
  } catch (err) {
    State.devices = [];
    // both slots, or the second keeps quoting a count from the last good scan
    for (const slot of [1, 2]) $(SLOTS[slot].hint).textContent = err.message;
  }
  select.innerHTML = "";
  if (!State.devices.length) {
    select.append(el("option", {value: "", text: "no devices found"}));
  }
  for (const dev of State.devices) {
    const label = dev.model
      ? dev.serial + "  (" + dev.model + ", " + dev.state + ")"
      : dev.serial + "  (" + dev.state + ")";
    select.append(el("option", {value: dev.serial, text: label}));
  }
  const saved = State.settings.serial;
  if (saved && State.devices.some((d) => d.serial === saved)) {
    select.value = saved;
  } else if (State.devices.length === 1) {
    select.value = State.devices[0].serial;
    saveSettings({serial: select.value});
  } else {
    select.value = State.settings.serial || "";
  }
  if ($("#second-device-toggle").checked) applyCompanionDevice();
  updateDeviceChip();
  if (select.value) loadPackages(1);
}

function updateDeviceChip() {
  const chip = $("#device-chip");
  const serial = State.settings.serial;
  if (serial) {
    const second = State.settings.second_device ? serialForSlot(2) : "";
    chip.textContent = second ? serial + " + " + second : serial;
    chip.className = "badge ok";
  } else {
    chip.textContent = "no device";
    chip.className = "badge";
  }
}

async function updateDeviceChipQuietly() {
  try {
    const data = await api("/api/devices");
    State.devices = data.devices || [];
    const online = State.devices.some(
      (d) => d.serial === State.settings.serial && d.state === "device");
    const chip = $("#device-chip");
    if (!State.devices.length) {
      chip.textContent = "no device";
      chip.className = "badge";
    } else if (!online) {
      const first = State.devices[0];
      chip.textContent = first.serial + (first.state !== "device"
        ? " (" + first.state + ")" : "");
      chip.className = "badge warn";
    } else {
      updateDeviceChip();
    }
    // studio may have booted before the device was plugged in; recover the
    // package list as soon as it shows up
    if (online && !packagesFor(1).length) loadPackages(1);
  } catch (e) { /* ignore polling hiccups */ }
}

async function loadPackages(slot) {
  const s = SLOTS[slot];
  const serial = serialForSlot(slot);
  const hint = $(s.hint);
  if (!serial) { hint.textContent = "connect a device first"; return; }
  hint.textContent = "loading packages...";
  try {
    const scope = State.settings.scope || "user";
    const data = await api("/api/apps?serial=" + encodeURIComponent(serial) +
                           "&scope=" + scope);
    // Keyed by serial rather than by slot, so switching either device keeps the
    // other slot's list instead of throwing it away.
    State.packagesBySerial[serial] = (data.packages || []).map((p) => p.package);
    hint.textContent = State.packagesBySerial[serial].length + " packages";
    renderAppOptions(slot);
  } catch (err) {
    hint.textContent = err.message;
  }
}

function renderAppOptions(slot) {
  // Kept as the refresh entry point: re-render the suggestion dropdown if
  // it is currently visible (e.g. after the package list or filter changes).
  if (!$(SLOTS[slot].sug).hidden) renderAppSuggestions(slot);
}

/* Custom package suggestions. The native datalist was dropped because
   browsers hide it whenever the input text already matches (a previously
   chosen id left an empty-looking dropdown). This one filters by what is
   typed but falls back to the full filtered list so there is always
   something to pick from. */
const Suggest = {1: {items: [], active: -1}, 2: {items: [], active: -1}};

function packagesFor(slot) {
  return State.packagesBySerial[serialForSlot(slot)] || [];
}

function filteredPackages(slot) {
  const needle = ($(SLOTS[slot].filter).value || "").trim().toLowerCase();
  const pool = packagesFor(slot);
  return needle
    ? pool.filter((p) => p.toLowerCase().includes(needle))
    : pool.slice();
}

function renderAppSuggestions(slot) {
  const box = $(SLOTS[slot].sug);
  const typed = ($(SLOTS[slot].app).value || "").trim().toLowerCase();
  let items = filteredPackages(slot);
  if (typed) {
    const matches = items.filter((p) => p.toLowerCase().includes(typed));
    items = matches.length ? matches : filteredPackages(slot);
  }
  Suggest[slot] = {items: items.slice(0, 300), active: -1};
  box.innerHTML = "";
  if (!packagesFor(slot).length) {
    box.append(el("li", {class: "hint", text: "no packages loaded yet"}));
    box.hidden = false;
    return;
  }
  for (const pkg of Suggest[slot].items) {
    box.append(el("li", {text: pkg,
                         onmousedown: (event) => {
                           event.preventDefault();  // keep input focus
                           pickApp(slot, pkg);
                         }}));
  }
  if (!Suggest[slot].items.length) {
    box.append(el("li", {class: "hint", text: "no installed package matches"}));
  }
  box.hidden = false;
}

function highlightSuggestion(slot) {
  const lis = $$(SLOTS[slot].sug + " li:not(.hint)");
  const active = Suggest[slot].active;
  lis.forEach((li, i) => li.classList.toggle("active", i === active));
  if (lis[active] && lis[active].scrollIntoView) {
    lis[active].scrollIntoView({block: "nearest"});
  }
}

function closeAppSuggestions(slot) {
  $(SLOTS[slot].sug).hidden = true;
  Suggest[slot] = {items: [], active: -1};
}

function pickApp(slot, pkg) {
  const s = SLOTS[slot];
  $(s.app).value = pkg;
  closeAppSuggestions(slot);
  saveSettings({[s.appKey]: pkg});
  resolveActivity(slot);
}

async function resolveActivity(slot) {
  const s = SLOTS[slot];
  const serial = serialForSlot(slot);
  const pkg = $(s.app).value.trim();
  if (!serial || !pkg) return;
  $(s.act).placeholder = "resolving...";
  try {
    const data = await api("/api/activity", {
      method: "POST",
      body: {serial, package: pkg},
    });
    $(s.act).value = data.activity;
    $(s.act).placeholder = "launch activity (auto)";
    saveSettings({[s.appKey]: pkg, [s.actKey]: data.activity});
    toast("resolved: " + data.activity, "ok");
  } catch (err) {
    $(s.act).placeholder = "launch activity (auto)";
    toast("could not resolve activity: " + err.message, "error");
  }
}

/* ========================================================== NARRATION TAB */

function bindNarrationTab(state) {
  const radios = $$('input[name="engine"]');
  for (const radio of radios) {
    radio.checked = radio.value === (State.settings.engine || "piper");
    if (radio.value === "say" && !state.darwin) {
      radio.disabled = true;
      radio.parentElement.title = "the say engine is macOS-only";
    }
    radio.addEventListener("change", () => {
      if (radio.checked) {
        saveSettings({engine: radio.value});
        applyEngineVisibility();
      }
    });
  }

  $("#voice-filter").addEventListener("input", debounce(renderSayVoices, 150));
  $("#voice-select").addEventListener("change", () =>
    saveSettings({voice: $("#voice-select").value}));

  const rateInput = $("#rate-input");
  const rateSlider = $("#rate-slider");
  rateInput.value = State.settings.rate || 180;
  rateSlider.value = rateInput.value;
  rateSlider.addEventListener("input", () => {
    rateInput.value = rateSlider.value;
  });
  const pushRate = () => {
    rateSlider.value = rateInput.value;
    saveSettings({rate: String(rateInput.value || "")});
  };
  rateInput.addEventListener("change", pushRate);
  rateSlider.addEventListener("change", pushRate);

  $("#piper-model-select").addEventListener("change", () => {
    const file = $("#piper-model-select").value;
    $("#piper-model-path").value = file;
    saveSettings({piper_model: file});
  });
  $("#piper-model-path").addEventListener("change", () =>
    saveSettings({piper_model: $("#piper-model-path").value.trim()}));
  $("#piper-bin").addEventListener("change", () =>
    saveSettings({piper_bin: $("#piper-bin").value.trim()}));

  $("#catalog-filter").addEventListener("input", debounce(renderCatalog, 200));
  $("#catalog-refresh").addEventListener("click", () => loadCatalog(true));

  $("#preview-play").addEventListener("click", playPreview);
}

/* ---------------- downloadable Piper voices ---------------- */

async function loadCatalog(force) {
  const hint = $("#catalog-hint");
  try {
    State.catalog = await api("/tts/catalog" + (force ? "?refresh=1" : ""));
    renderCatalog();
    if (force) {
      toast(State.catalog.source === "network"
        ? "voice list refreshed (" + State.catalog.voices.length + " voices)"
        : "voice list from " + State.catalog.source +
          " (network unreachable)", "ok");
    }
  } catch (err) {
    hint.textContent = err.message;
    hint.style.color = "var(--err)";
  }
  pollDownloadStatus();
}

function renderCatalog() {
  const list = $("#catalog-list");
  const hint = $("#catalog-hint");
  hint.textContent = "";
  list.innerHTML = "";
  if (!State.catalog || !State.catalog.voices.length) return;
  const needle = ($("#catalog-filter").value || "").trim().toLowerCase();
  const voices = State.catalog.voices.filter((v) =>
    !needle || (v.key + " " + v.locale).toLowerCase().includes(needle));
  for (const voice of voices.slice(0, 400)) {
    list.append(catalogRow(voice));
  }
  const shown = Math.min(voices.length, 400);
  const source = State.catalog.source;
  hint.style.color = "";
  hint.textContent = shown + " of " + State.catalog.voices.length +
    " voices" + (source !== "network"
      ? "  (list from " + source + "; hit Refresh to retry the network)" : "");
}

function mb(bytes) {
  return bytes ? Math.round(bytes / (1024 * 1024)) + " MB" : "size unknown";
}

function catalogRow(voice) {
  const row = el("li", {class: "catalog-row", "data-key": voice.key});
  row.append(el("span", {class: "name mono", text: voice.key}),
             el("span", {class: "meta",
                         text: voice.locale + " - " + voice.quality +
                               " - " + mb(voice.size_bytes)}),
             el("span", {class: "spacer"}));
  row.append(catalogAction(voice));
  return row;
}

function catalogAction(voice) {
  if (voice.installed) {
    return el("span", {class: "badge ok", text: "installed"});
  }
  const btn = el("button", {
    class: "ghost small-btn",
    text: "Download",
    onclick: async () => {
      try {
        await api("/tts/download", {method: "POST", body: {key: voice.key}});
        setCatalogRowText(voice.key, "starting...");
        pollDownloadStatus();
      } catch (err) {
        toast(err.message, "error");
      }
    },
  });
  btn.dataset.download = voice.key;
  return btn;
}

function setCatalogRowText(key, text) {
  const row = $('.catalog-row[data-key="' + CSS.escape(key) + '"]');
  if (!row) return;
  let status = $(".status", row);
  if (!status) {
    status = el("span", {class: "status mono small"});
    row.append(status);
  }
  status.textContent = text;
}

let downloadTimer = null;
async function pollDownloadStatus() {
  clearInterval(downloadTimer);
  try {
    const status = await api("/tts/download/status");
    updateCatalogProgress(status);
    if (status.running) {
      downloadTimer = setInterval(async () => {
        try {
          updateCatalogProgress(await api("/tts/download/status"));
        } catch (e) { /* transient */ }
      }, 700);
    }
  } catch (e) { /* endpoint unavailable */ }
}

function updateCatalogProgress(status) {
  $$("#catalog-list [data-download]").forEach((b) => { b.disabled = false; });
  if (status.running && status.key) {
    const pct = status.total
      ? Math.round(status.got * 100 / status.total) + "%" : "";
    const size = status.total
      ? " (" + Math.round(status.got / (1024 * 1024)) + "/" +
        Math.round(status.total / (1024 * 1024)) + " MB)" : "";
    setCatalogRowText(status.key,
                      "downloading " + (pct || "...") + size);
    const btn = $('#catalog-list [data-download="' +
                 CSS.escape(status.key) + '"]');
    if (btn) btn.disabled = true;
    return;
  }
  if (status.done || status.error) {
    if (status.error) toast("download failed: " + status.error, "error");
    else toast("voice downloaded; it is now in the model picker", "ok");
    loadVoices();
    loadCatalog(false);
  }
}

function applyEngineVisibility() {
  const engine = State.settings.engine || "piper";
  $("#say-card").style.display = engine === "say" ? "" : "none";
  $("#piper-card").style.display = engine === "piper" ? "" : "none";
  const hints = [];
  if (engine === "say" && !State.darwin) {
    hints.push("say is unavailable here; choose Piper or none.");
  }
  if (engine === "piper") {
    if (!State.piperBinary) {
      hints.push("piper binary was not found; set its path below " +
                 "(or install it, e.g. pip install piper-tts).");
    }
    if (!State.piperVoices.length) {
      hints.push("no Piper voice models found; download one from " +
                 "huggingface.co/rhasspy/piper-voices into piper-voices/.");
    }
  }
  $("#engine-hint").textContent = hints.join(" ");
}

async function loadVoices() {
  try {
    const data = await api("/tts/voices");
    State.sayVoices = data.say || [];
    State.piperVoices = data.piper || [];
    State.piperBinary = data.piper_binary || null;
    renderSayVoices();
    renderPiperModels();
    applyEngineVisibility();
  } catch (err) {
    toast("could not list voices: " + err.message, "error");
  }
}

function renderSayVoices() {
  const select = $("#voice-select");
  const needle = ($("#voice-filter").value || "").toLowerCase();
  select.innerHTML = "";
  const voices = State.sayVoices.filter((v) =>
    !needle || v.name.toLowerCase().includes(needle) ||
    v.locale.toLowerCase().includes(needle));
  const groups = new Map();
  for (const voice of voices) {
    const locale = voice.locale || "other";
    if (!groups.has(locale)) groups.set(locale, []);
    groups.get(locale).push(voice);
  }
  for (const [locale, items] of [...groups.entries()].sort()) {
    const group = el("optgroup", {label: locale});
    for (const v of items) {
      const label = v.name + (v.sample ? "   -   " + v.sample : "");
      group.append(el("option", {value: v.name, text: label}));
    }
    select.append(group);
  }
  const saved = State.settings.voice;
  if (saved && voices.some((v) => v.name === saved)) select.value = saved;
  else if (!saved && voices.length) {
    const samantha = voices.find((v) => v.name === "Samantha");
    select.value = samantha ? samantha.name : voices[0].name;
  } else {
    select.value = "";
  }
}

function renderPiperModels() {
  const select = $("#piper-model-select");
  select.innerHTML = "";
  for (const model of State.piperVoices) {
    select.append(el("option", {value: model.file, text: model.name}));
  }
  const saved = State.settings.piper_model || "";
  if (saved) {
    const match = State.piperVoices.find((m) => m.file === saved);
    if (match) select.value = saved;
    else select.append(el("option", {value: saved, text: saved}));
  }
  $("#piper-model-path").value = saved;
  if (State.piperBinary) {
    $("#piper-bin").placeholder =
      "piper binary path (auto-detected: " + State.piperBinary + ")";
  }
  $("#piper-hint").textContent = State.piperBinary
    ? "using piper at " + State.piperBinary
    : "piper binary not detected on PATH.";
}

let previewPending = false;
async function playPreview() {
  if (previewPending) return;
  const engine = State.settings.engine || "say";
  if (engine === "none") {
    toast("narration is off; nothing to preview", "error");
    return;
  }
  previewPending = true;
  const btn = $("#preview-play");
  btn.disabled = true;
  btn.textContent = "synthesizing...";
  $("#preview-hint").textContent = "";
  try {
    const body = {engine};
    if (engine === "say") {
      body.voice = $("#voice-select").value;
      body.rate = $("#rate-input").value;
    } else {
      body.model = $("#piper-model-path").value.trim();
      body.piper_bin = $("#piper-bin").value.trim();
    }
    const text = $("#preview-text").value.trim();
    if (text) body.text = text;
    const data = await api("/tts/sample", {method: "POST", body});
    const audio = $("#preview-audio");
    audio.src = encodeURI(data.url);
    await audio.play();
  } catch (err) {
    $("#preview-hint").textContent = err.message;
    $("#preview-hint").style.color = "var(--err)";
  } finally {
    previewPending = false;
    btn.disabled = false;
    btn.textContent = "Play sample";
  }
}

/* ============================================================== STEPS TAB */

async function loadSchema() {
  const data = await api("/api/schema");
  State.schema = data.actions;
  State.defaultOrder = data.default_order;
  State.specSchema = data.spec_actions || data.actions;
  State.specOrder = data.spec_default_order || data.default_order;
  populateActionSelect();
}

function populateActionSelect() {
  const select = $("#add-action-select");
  const schema = schemaFor();
  const order = Editor.mode === "scenario" ? State.specOrder : State.defaultOrder;
  select.innerHTML = "";
  for (const action of order) {
    if (schema[action]) {
      select.append(el("option", {value: action, text: schema[action].label}));
    }
  }
}

function markDirty(dirty) {
  State.dirty = dirty;
  $("#dirty-flag").hidden = !dirty;
}

async function loadSteps(path) {
  try {
    const data = await api("/api/steps?path=" + encodeURIComponent(path));
    Editor.mode = "demo";
    Editor.filePath = "";
    Editor.entryIndex = -1;
    State.steps = data.steps;
    State.stepsPath = data.path;
    State.errors = data.errors || [];
    State.recents = data.recents || [];
    $("#steps-file").textContent = data.path;
    syncEditorModeUI();
    markDirty(false);
    renderTree();
    renderValidation();
    renderRecents();
  } catch (err) {
    toast(err.message, "error");
  }
}

function renderRecents() {
  const select = $("#recents-select");
  select.innerHTML = '<option value="">recent...</option>';
  for (const recent of State.recents) {
    select.append(el("option", {value: recent, text: recent}));
  }
}

function syncEditorModeUI() {
  const scenario = Editor.mode === "scenario";
  $("#scenario-name").hidden = !scenario;
  $("#steps-run").disabled = scenario;
  $("#steps-dryrun").disabled = scenario;
  populateActionSelect();
}

function bindStepsToolbar() {
  $("#recents-select").addEventListener("change", () => {
    if ($("#recents-select").value) loadSteps($("#recents-select").value);
  });
  $("#steps-open").addEventListener("click", () =>
    openPicker({
      title: "Open steps JSON",
      mode: "file",
      filter: (name) => name.endsWith(".json"),
      onUse: (path) => loadSteps(path),
    }));
  $("#steps-save").addEventListener("click", saveSteps);
  $("#steps-validate").addEventListener("click",
    () => validateStepsRemote(false));
  $("#steps-run").addEventListener("click", async () => {
    activateTab("run");
    await startRun("normal");
  });
  $("#steps-dryrun").addEventListener("click", async () => {
    activateTab("run");
    await startRun("dry");
  });
  $("#scenario-name").addEventListener("change", () => {
    if (Editor.mode !== "scenario") return;
    const entry = State.specDoc[Editor.entryIndex];
    if (!entry) return;
    entry.name = $("#scenario-name").value.trim();
    updateStepsFileLabel();
    markDirty(true);
  });
  $("#add-step-top").addEventListener("click", () => {
    addActionInto(activeSteps(), "");
  });
}

function updateStepsFileLabel() {
  if (Editor.mode === "scenario") {
    const entry = State.specDoc[Editor.entryIndex] || {};
    $("#steps-file").textContent =
      Editor.filePath + "  [" + Editor.entryIndex + "] " +
      (entry.name || "(unnamed)") + "   (spec test)";
  } else {
    $("#steps-file").textContent = State.stepsPath;
  }
}

function currentStepsPath() {
  return State.stepsPath || State.settings.steps_path || "";
}

async function saveSteps() {
  const path = currentStepsPath();
  if (!path) {
    openPicker({
      title: "Save steps JSON as",
      mode: "save",
      filter: (name) => name.endsWith(".json"),
      onUse: (chosen) => writeSteps(chosen),
    });
    return;
  }
  await writeSteps(path);
}

async function writeSteps(path) {
  if (Editor.mode === "scenario") return saveScenarioDoc();
  try {
    const data = await api("/api/steps", {
      method: "PUT",
      body: {path, steps: State.steps},
    });
    State.stepsPath = data.path;
    $("#steps-file").textContent = data.path;
    State.errors = [];
    markDirty(false);
    renderValidation();
    toast("saved " + data.path, "ok");
  } catch (err) {
    if (err.message.startsWith("HTTP 422")) {
      // re-fetch precise errors from the validator
      await validateStepsRemote(true);
      toast("validation failed; fix highlighted steps", "error");
    } else {
      toast("save failed: " + err.message, "error");
    }
  }
}

async function saveScenarioDoc() {
  try {
    const data = await api("/api/spec/file", {
      method: "PUT",
      body: {path: Editor.filePath, doc: State.specDoc},
    });
    State.errors = [];
    markDirty(false);
    renderValidation();
    toast("saved " + (data.path || Editor.filePath), "ok");
    loadSpecState(true);
  } catch (err) {
    if (err.message.startsWith("HTTP 422")) {
      // highlight the offending steps of the entry being edited
      await validateStepsRemote(true);
      toast("validation failed; fix highlighted steps", "error");
    } else {
      toast("save failed: " + err.message, "error");
    }
  }
}

async function validateStepsRemote(silentOk) {
  try {
    const data = await api("/api/steps/validate", {
      method: "POST",
      body: {steps: activeSteps(),
             registry: Editor.mode === "scenario" ? "spec" : ""},
    });
    State.errors = data.errors || [];
    renderValidation();
    renderTree();
    if (!silentOk) {
      toast(State.errors.length
        ? State.errors.length + " issue(s) found"
        : "all steps valid", State.errors.length ? "error" : "ok");
    }
  } catch (err) {
    toast(err.message, "error");
  }
}

function renderValidation() {
  const banner = $("#validation-banner");
  if (!State.errors.length) {
    banner.hidden = true;
    banner.textContent = "";
    return;
  }
  banner.hidden = false;
  banner.textContent = State.errors.length + " issue(s): " +
    State.errors.map((e) => (e.path || "root") + " " + e.message).join("; ");
}

function errorsAt(path) {
  return State.errors.filter((e) => e.path === path);
}

function stepSummary(step) {
  if (!step || typeof step !== "object") return "";
  const parts = [];
  const interesting = ["text", "watch_for", "desc", "contains", "direction",
                       "delta", "from_text", "to_text", "to_desc",
                       "duration_ms", "command", "x", "y", "source", "expect"];
  for (const key of interesting) {
    const value = step[key];
    if (value !== undefined && value !== "") parts.push(key + "=" + value);
  }
  if (step.action === "tap_xy") parts.unshift("");
  if (step.narration) parts.push('"' + String(step.narration).slice(0, 60) + '"');
  return parts.filter(Boolean).join("  ");
}

function renderTree() {
  const root = $("#steps-tree");
  root.innerHTML = "";
  renderStepArray(activeSteps(), root, "");
}

function renderStepArray(stepsArr, container, prefix) {
  stepsArr.forEach((step, index) => {
    const path = prefix + "[" + index + "]";
    container.append(buildStepNode(step, path, stepsArr, index));
  });
}

function buildStepNode(step, path, siblings, index) {
  const action = step ? step.action : "?";
  const meta = schemaFor()[action] || {label: action || "unknown"};
  const nodeErrors = errorsAt(path);

  const head = el("div", {class: "step-head"},
    el("span", {class: "step-action", text: meta.label}),
    el("span", {class: "step-summary mono",
                text: stepSummary(step)}),
    el("span", {class: "step-buttons"},
      iconButton("edit", () => openStepEditor(path)),
      iconButton("dup", () => duplicateStep(siblings, index)),
      iconButton("up", () => moveStep(siblings, index, -1)),
      iconButton("dn", () => moveStep(siblings, index, 1)),
      iconButton("del", () => deleteStep(siblings, index))));

  const node = el("li", {class: "step-node" + (nodeErrors.length
    ? " error-node" : ""), "data-path": path}, head);

  for (const issue of nodeErrors) {
    node.append(el("div", {class: "step-error", text: issue.message}));
  }

  if (action === "if") {
    for (const branchName of ["then", "else"]) {
      const branch = Array.isArray(step[branchName]) ? step[branchName] : [];
      const branchList = el("ol", {class: "tree-root"});
      renderStepArray(branch, branchList, path + "." + branchName);
      const addBtn = iconButton("+ add", () => {
        addActionInto(branch, path + "." + branchName);
      });
      node.append(
        el("div", {class: "branch-label" + (branchName === "else"
          ? " else" : ""), text: branchName}),
        el("div", {class: "branch"}, branchList,
          el("div", {class: "row"}, addBtn)));
    }
  }
  return node;
}

function iconButton(label, onClick) {
  return el("button", {type: "button", text: label, onclick: onClick});
}

function getPathArray(pathStr) {
  // "[2].then[1]" -> array that contains that step
  const topMatch = pathStr.match(/^\[(\d+)\]/);
  if (!topMatch) return null;
  return activeSteps();
}

function findContainerAndIndex(pathStr) {
  // returns {arr, index} for the LAST bracket in the path
  const matches = [...pathStr.matchAll(/\[(\d+)\]/g)];
  if (!matches.length) return null;
  const last = matches[matches.length - 1];
  const index = parseInt(last[1], 10);
  let arr = activeSteps();
  const upTo = pathStr.slice(0, last.index);
  const parents = [...upTo.matchAll(/\.?(then|else)\[(\d+)\]/g)];
  let cursorPath = "";
  for (const parent of parents) {
    cursorPath += "." + parent[1] + "[" + parent[2] + "]";
  }
  if (upTo.includes(".then") || upTo.includes(".else")) {
    arr = resolveBranch(upTo);
  }
  return {arr, index};
}

function resolveBranch(prefixPath) {
  // prefixPath like "[2].then[0]" -> the array at "[2].then"
  const branchName = prefixPath.endsWith(".then") ? "then"
    : prefixPath.includes(".else") ? "else" : null;
  if (!prefixPath.includes(".")) return activeSteps();
  const withoutIndex = prefixPath.replace(/\[\d+\]$/, "");
  const stepPath = withoutIndex.replace(/\.(then|else)$/, "");
  const branch = withoutIndex.match(/\.(then|else)$/);
  const stepRef = deref(stepPath);
  if (stepRef && branch) {
    if (!Array.isArray(stepRef[branch[1]])) stepRef[branch[1]] = [];
    return stepRef[branch[1]];
  }
  return activeSteps();
}

function deref(pathStr) {
  // "[0].then[1]" -> actual step object at that position
  const tokens = [...pathStr.matchAll(/\[(\d+)\]|\.(then|else)/g)];
  let arr = activeSteps();
  let obj = null;
  let pendingBranch = null;
  for (const token of tokens) {
    if (token[1] !== undefined) {
      obj = arr[parseInt(token[1], 10)];
      if (pendingBranch && obj) {
        if (!Array.isArray(obj[pendingBranch])) obj[pendingBranch] = [];
        arr = obj[pendingBranch];
        pendingBranch = null;
      }
    } else {
      pendingBranch = token[2];
    }
  }
  return obj;
}

function mutate(fn, description) {
  fn();
  markDirty(true);
  renderTree();
  refreshCommandPreviewSoon();
  if (description) void description;
}

function addActionInto(arr, branchPath) {
  const action = $("#add-action-select").value;
  if (!action) return;
  const fresh = freshStep(action);
  arr.push(fresh);
  mutate(() => {}, null);
  openStepEditor(pathForNew(arr, branchPath), true);
}

function freshStep(action) {
  const step = {action};
  const meta = schemaFor()[action] || {fields: []};
  for (const spec of meta.fields) {
    if (spec.type === "steps") continue;
    if (spec.default !== null && spec.default !== undefined) {
      step[spec.name] = spec.default;
    }
  }
  return step;
}

function pathForNew(arr, branchPath) {
  const idx = arr.length - 1;
  return branchPath ? branchPath + "[" + idx + "]" : "[" + idx + "]";
}

function duplicateStep(siblings, index) {
  mutate(() => {
    siblings.splice(index + 1, 0,
      JSON.parse(JSON.stringify(siblings[index])));
  });
}

function moveStep(siblings, index, delta) {
  const target = index + delta;
  if (target < 0 || target >= siblings.length) return;
  mutate(() => {
    const [item] = siblings.splice(index, 1);
    siblings.splice(target, 0, item);
  });
}

function deleteStep(siblings, index) {
  mutate(() => siblings.splice(index, 1));
}

/* ---------------- step editor dialog ---------------- */

let editingPath = null;

function openStepEditor(path, isNew) {
  editingPath = path;
  const step = deref(path);
  if (!step) return;
  $("#step-dialog-title").textContent =
    (isNew ? "New step: " : "Edit: ") +
    ((schemaFor()[step.action] || {}).label || step.action);
  buildStepFields(step);
  $("#step-delete").style.display = isNew ? "none" : "";
  $("#step-dialog").showModal();
}

function buildStepFields(step) {
  const box = $("#step-fields");
  box.innerHTML = "";
  const specs = (schemaFor()[step.action] || {fields: []}).fields;
  for (const spec of specs) {
    if (spec.type === "steps") continue;
    box.append(fieldBlock(spec, step));
  }
  wireConditionalVisibility(box);
}

function fieldBlock(spec, step) {
  const block = el("div", {class: "field-block"});
  block.dataset.whenField = spec.when ? spec.when.field : "";
  block.dataset.whenValue = spec.when ? spec.when.value : "";

  const label = el("label", {text: spec.name});
  if (spec.required) label.append(el("span", {class: "req", text: " *"}));
  block.append(label);

  const value = step[spec.name];
  let input;
  if (spec.type === "select") {
    input = el("select");
    for (const option of spec.options || []) {
      input.append(el("option", {value: option, text: option}));
    }
    input.value = value !== undefined && value !== null && value !== ""
      ? String(value) : (spec.default || "");
  } else if (spec.type === "multiline") {
    input = el("textarea");
    input.value = value === undefined || value === null ? "" : String(value);
  } else if (spec.type === "int" || spec.type === "num") {
    input = el("input", {type: "number",
                         step: spec.type === "int" ? "1" : "any"});
    if (value !== undefined && value !== null) input.value = String(value);
    else if (spec.default !== undefined && spec.default !== null) {
      input.value = String(spec.default);
    }
  } else {
    input = el("input", {type: "text"});
    input.value = value === undefined || value === null ? "" : String(value);
  }
  input.dataset.field = spec.name;
  input.dataset.ftype = spec.type;
  block.append(input);

  if (spec.help) {
    block.append(el("div", {class: "field-help", text: spec.help}));
  }
  return block;
}

function wireConditionalVisibility(box) {
  const apply = () => {
    const source = $('[data-field="source"]', box);
    const current = source ? source.value : "";
    for (const block of $$(".field-block", box)) {
      if (!block.dataset.whenField) continue;
      const show = block.dataset.whenValue === current;
      block.style.display = show ? "" : "none";
    }
  };
  const source = $('[data-field="source"]', box);
  if (source) source.addEventListener("change", apply);
  apply();
}

function bindDialogs() {
  bindStepsToolbar();
  $$("dialog [data-close]").forEach((btn) => {
    btn.addEventListener("click", () => btn.closest("dialog").close());
  });

  $("#step-form").addEventListener("submit", (event) => {
    event.preventDefault();
    applyStepEdits();
  });
  $("#step-delete").addEventListener("click", () => {
    const found = findContainerAndIndex(editingPath);
    $("#step-dialog").close();
    if (found) deleteStep(found.arr, found.index);
  });
  $("#picker-use").addEventListener("click", usePickerSelection);
  $("#picker-manual").addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      pickerNavigate($("#picker-manual").value.trim());
    }
  });
}

function applyStepEdits() {
  const step = deref(editingPath);
  if (!step) { $("#step-dialog").close(); return; }
  for (const input of $$("#step-fields [data-field]")) {
    const name = input.dataset.field;
    const ftype = input.dataset.ftype;
    let value = input.value;
    if (ftype === "int" || ftype === "num") {
      if (String(value).trim() === "") delete step[name];
      else step[name] = Number(value);
    } else if (String(value).trim() === "" && !input.required) {
      delete step[name];
    } else {
      step[name] = value;
    }
  }
  markDirty(true);
  renderTree();
  $("#step-dialog").close();
}

/* ---------------- file/folder picker dialog ---------------- */

const Picker = {mode: "dir", path: "", onUse: null, filter: null};

function openPicker(configObj) {
  Object.assign(Picker, configObj);
  $("#picker-title").textContent = configObj.title || "Choose";
  $("#picker-use").textContent =
    configObj.mode === "dir" ? "Use folder" :
    configObj.mode === "save" ? "Save here" : "Open";
  $("#picker-list").innerHTML = "";
  pickerNavigate(configObj.start || State.settings.out_dir ||
                 State.stepsPath || "");
  $("#picker-dialog").showModal();
}

async function pickerNavigate(path) {
  try {
    const data = await api("/api/browse?path=" + encodeURIComponent(path) +
      "&show_files=" + (Picker.mode === "dir" ? "0" : "1"));
    Picker.path = data.path;
    renderPicker(data);
  } catch (err) {
    toast(err.message, "error");
  }
}

function renderPicker(data) {
  $("#picker-crumbs").textContent = data.path;
  $("#picker-manual").value = data.path;
  const list = $("#picker-list");
  list.innerHTML = "";
  if (data.parent && data.parent !== data.path) {
    list.append(pickerRow("..", "parent", () => pickerNavigate(data.parent)));
  }
  for (const dir of data.dirs) {
    list.append(pickerRow(dir, "folder", () =>
      pickerNavigate(data.path.replace(/\/$/, "") + "/" + dir)));
  }
  if (Picker.mode !== "dir") {
    for (const file of data.files || []) {
      if (Picker.filter && !Picker.filter(file)) continue;
      list.append(pickerRow(file, "file", (event, row) => {
        $$(".selected", list).forEach((r) => r.classList.remove("selected"));
        row.classList.add("selected");
        Picker.selectedFile = data.path.replace(/\/$/, "") + "/" + file;
      }));
    }
  }
}

function pickerRow(name, kind, onClick) {
  const row = el("li", {}, el("span", {text: name}),
                 el("span", {class: "kind", text: kind}));
  row.addEventListener("click", (event) => onClick(event, row));
  return row;
}

function usePickerSelection() {
  let chosen = Picker.path;
  if (Picker.mode === "dir") {
    $("#picker-dialog").close();
    Picker.onUse(chosen);
    return;
  }
  chosen = Picker.selectedFile || $("#picker-manual").value.trim();
  if (!chosen) { toast("nothing selected", "error"); return; }
  if (Picker.mode === "save" && !chosen.endsWith(".json")) {
    chosen += ".json";
  }
  $("#picker-dialog").close();
  Picker.onUse(chosen);
}

function bindOutputTab() {
  $("#out-dir-browse").addEventListener("click", () => {
    openPicker({
      title: "Choose output folder",
      mode: "dir",
      start: State.settings.out_dir,
      onUse: (dir) => {
        $("#out-dir").value = dir;
        saveSettings({out_dir: dir});
      },
    });
  });
  $("#out-dir").addEventListener("change", () =>
    saveSettings({out_dir: $("#out-dir").value.trim()}));
  $("#out-name").addEventListener("change", () =>
    saveSettings({out_name: $("#out-name").value.trim()}));
  $("#segment-seconds").addEventListener("change", () =>
    saveSettings({segment_seconds: Number($("#segment-seconds").value) || 150}));
  $("#compose-height").addEventListener("change", () =>
    saveSettings({compose_height: Number($("#compose-height").value) || 1080}));
  $("#keep-workdir").addEventListener("change", () =>
    saveSettings({keep_workdir: $("#keep-workdir").checked}));
  $("#no-narration-force").addEventListener("change", () =>
    saveSettings({no_narration: $("#no-narration-force").checked}));
  $("#script-path").addEventListener("change", () =>
    saveSettings({script_path: $("#script-path").value.trim()}));
}

function fillOutputTab() {
  $("#out-dir").value = State.settings.out_dir || "";
  $("#out-name").value = State.settings.out_name || "";
  $("#segment-seconds").value = State.settings.segment_seconds || 150;
  $("#compose-height").value = State.settings.compose_height || 1080;
  $("#keep-workdir").checked = !!State.settings.keep_workdir;
  $("#no-narration-force").checked = !!State.settings.no_narration;
  $("#script-path").value = State.settings.script_path || "";
}

/* ================================================================ RUN TAB */

let previewTimer = null;
function refreshCommandPreviewSoon() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(refreshCommandPreview, 500);
}

async function refreshCommandPreview() {
  const box = $("#command-preview");
  try {
    const data = await api("/api/command", {
      method: "POST",
      body: {mode: "normal", settings: effectiveSettings()},
    });
    box.textContent = data.command;
    box.style.color = "var(--ok)";
  } catch (err) {
    box.textContent = "# " + err.message;
    box.style.color = "var(--err)";
  }
}

function effectiveSettings() {
  return {
    serial: State.settings.serial,
    app_id: $("#app-input") ? $("#app-input").value.trim()
                            : State.settings.app_id,
    activity: $("#activity-input") ? $("#activity-input").value.trim() : "",
    second_device: $("#second-device-toggle")
      ? $("#second-device-toggle").checked : !!State.settings.second_device,
    serial_2: $("#device-select-2") ? $("#device-select-2").value : "",
    app_id_2: $("#app-input-2") ? $("#app-input-2").value.trim() : "",
    activity_2: $("#activity-input-2") ? $("#activity-input-2").value.trim() : "",
    steps_path: currentStepsPath(),
    out_dir: $("#out-dir").value,
    out_name: $("#out-name").value,
    segment_seconds: Number($("#segment-seconds").value) || 150,
    compose_height: Number($("#compose-height").value) || 1080,
    engine: State.settings.engine,
    voice: $("#voice-select") ? $("#voice-select").value : "",
    rate: $("#rate-input") ? $("#rate-input").value : "",
    piper_model: $("#piper-model-path") ? $("#piper-model-path").value : "",
    piper_bin: $("#piper-bin") ? $("#piper-bin").value : "",
    keep_workdir: $("#keep-workdir").checked,
    no_narration: $("#no-narration-force").checked,
    script_path: State.settings.script_path,
  };
}

function bindRunTab() {
  $("#run-copy").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("#command-preview").textContent);
      toast("command copied", "ok");
    } catch (err) {
      toast("copy blocked by browser; select the text manually", "error");
    }
  });
  $("#run-start").addEventListener("click", () => startRun("normal"));
  $("#run-dry").addEventListener("click", () => startRun("dry"));
  $("#run-cancel").addEventListener("click", cancelRun);
}

async function startRun(mode) {
  if (State.dirty) {
    try {
      await writeSteps(currentStepsPath());
    } catch (err) {
      toast("save the steps before running: " + err.message, "error");
      return;
    }
  }
  try {
    await api("/api/run", {
      method: "POST",
      body: {mode, settings: effectiveSettings()},
    });
    $("#run-log").innerHTML = "";
    State.pollOffset = 0;
    setRunningUI(true);
    startPolling();
  } catch (err) {
    toast(err.message, "error");
  }
}

async function cancelRun() {
  try {
    await api("/api/run/cancel", {method: "POST"});
    toast("cancel signal sent", "ok");
  } catch (err) {
    toast(err.message, "error");
  }
}

function setRunningUI(running) {
  $("#run-start").disabled = running;
  $("#run-dry").disabled = running;
  $("#run-cancel").disabled = !running;
  const chip = $("#run-chip");
  if (running) {
    chip.textContent = "running...";
    chip.className = "badge busy";
  }
}

async function resumePollingIfRunning() {
  const status = await api("/api/run/status?since=0");
  if (status.running) {
    setRunningUI(true);
    if (status.kind === "spec") startSpecPolling();
    else startPolling();
  } else if (status.kind === "spec" && status.exit_code !== null &&
             status.exit_code !== undefined) {
    // a finished spec run from an earlier session: restore its report
    $("#spec-log").hidden = false;
    State.specOffset = status.offset;
    renderSpecFinished(status);
  }
}

function startPolling() {
  clearInterval(State.pollTimer);
  State.pollTimer = setInterval(pollOnce, 700);
  pollOnce();
}

async function pollOnce() {
  let status;
  try {
    status = await api("/api/run/status?since=" + State.pollOffset);
  } catch (err) {
    return; // transient network hiccup; retry next tick
  }
  const logBox = $("#run-log");
  for (const line of status.lines) {
    const cls = /ERROR|error:/i.test(line) ? "log-line err"
      : line.startsWith("==> Done") ? "log-line ok" : "log-line";
    logBox.append(el("div", {class: cls, text: line}));
  }
  if (status.lines.length) logBox.scrollTop = logBox.scrollHeight;
  State.pollOffset = status.offset;

  if (!status.running && status.exit_code !== null &&
      status.exit_code !== undefined) {
    clearInterval(State.pollTimer);
    State.pollTimer = null;
    setRunningUI(false);
    const code = status.exit_code;
    const chip = $("#run-chip");
    if (code === 0) {
      chip.textContent = "done";
      chip.className = "badge ok";
    } else if (code === 130 || code === 143) {
      chip.textContent = "cancelled";
      chip.className = "badge warn";
    } else {
      chip.textContent = "exit " + code;
      chip.className = "badge err";
    }
    const result = $("#result-line");
    if (status.mp4_path && code === 0) {
      result.textContent = "video ready: " + status.mp4_path;
      result.style.color = "var(--ok)";
    } else {
      result.textContent = code === 0 ? "finished" : "run failed";
      result.style.color = code === 0 ? "var(--ok)" : "var(--err)";
    }
    refreshCommandPreview();
  }
}

/* ========================================================= SPEC TESTS TAB */

function ensureSpecLoaded() {
  if (State.specLoaded) return;
  State.specLoaded = true;
  $("#spec-app-id").value = State.settings.spec_app_id || "";
  $("#spec-activity").value = State.settings.spec_activity || "";
  $("#spec-dir").value = State.settings.spec_scenarios_dir || "";
  loadSpecState(true);
}

function bindSpecTab() {
  $("#spec-refresh").addEventListener("click", () => loadSpecState(false));
  $("#spec-dir").addEventListener("change", async () => {
    await saveSettings({spec_scenarios_dir: $("#spec-dir").value.trim()});
    loadSpecState(false);
  });
  $("#spec-dir-browse").addEventListener("click", () => openPicker({
    title: "Choose scenarios directory",
    mode: "dir",
    start: State.settings.spec_scenarios_dir,
    onUse: (dir) => {
      $("#spec-dir").value = dir;
      saveSettings({spec_scenarios_dir: dir});
      loadSpecState(false);
    },
  }));
  $("#spec-newfile").addEventListener("click", () => {
    if (!State.settings.spec_scenarios_dir) {
      toast("choose a scenarios directory first", "error");
      return;
    }
    openPicker({
      title: "New scenarios file",
      mode: "save",
      start: State.settings.spec_scenarios_dir,
      filter: (name) => name.endsWith(".json"),
      onUse: async (path) => {
        try {
          await api("/api/spec/file", {method: "PUT",
            body: {path,
                   doc: [{name: "New scenario",
                          steps: [{action: "launch"}]}]}});
          await loadSpecState(true);
          toast("created " + path, "ok");
        } catch (err) {
          toast(err.message, "error");
        }
      },
    });
  });
  $("#spec-app-id").addEventListener("change", () =>
    saveSettings({spec_app_id: $("#spec-app-id").value.trim()}));
  $("#spec-activity").addEventListener("change", () =>
    saveSettings({spec_activity: $("#spec-activity").value.trim()}));
  $("#spec-resolve").addEventListener("click", resolveSpecActivity);
  $("#spec-run-all").addEventListener("click", () => runSpec({}));
  $("#spec-cancel").addEventListener("click", cancelRun);
}

async function resolveSpecActivity() {
  const serial = State.settings.serial;
  const pkg = $("#spec-app-id").value.trim();
  if (!serial || !pkg) return;
  $("#spec-activity").placeholder = "resolving...";
  try {
    const data = await api("/api/activity",
                           {method: "POST", body: {serial, package: pkg}});
    $("#spec-activity").value = data.activity;
    $("#spec-activity").placeholder = "launch activity (auto)";
    saveSettings({spec_app_id: pkg, spec_activity: data.activity});
    toast("resolved: " + data.activity, "ok");
  } catch (err) {
    $("#spec-activity").placeholder = "launch activity (auto)";
    toast("could not resolve activity: " + err.message, "error");
  }
}

async function loadSpecState(silent) {
  try {
    const data = await api("/api/spec/state");
    if (document.activeElement !== $("#spec-dir")) {
      $("#spec-dir").value = data.dir || "";
    }
    renderSpecFiles(data);
    if (silent !== true) {
      const t = data.totals || {};
      toast("reloaded: " + t.files + " files, " + t.runnable +
            " scenarios, " + t.skipped + " skipped", "ok");
    }
  } catch (err) {
    $("#spec-files").innerHTML = "";
    $("#spec-files").append(el("p", {class: "hint", text: err.message}));
    if (silent !== true) toast(err.message, "error");
  }
}

function renderSpecFiles(data) {
  const box = $("#spec-files");
  box.innerHTML = "";
  const hints = [];
  if (!data.script_ok) {
    hints.push("android-spec-test.sh not found; check Output & Advanced " +
               "settings or run ./setup.sh.");
  }
  if (data.error) hints.push(data.error);
  if (!data.serial) hints.push("no device selected on the App tab.");
  if (!data.app_id) hints.push("set the app id under test above.");
  $("#spec-hint").textContent = hints.join(" ");
  $("#spec-hint").style.color = hints.length ? "var(--warn)" : "";

  const t = data.totals || {};
  $("#spec-totals").textContent =
    t.files + " files - " + t.runnable + " scenarios - " +
    t.skipped + " skipped - " + t.notes + " notes" +
    (t.error_files ? " - " + t.error_files + " unreadable" : "");

  if (!data.files.length && !hints.length) {
    box.append(el("p", {class: "hint",
                        text: "no *.json scenario files in that directory."}));
  }
  for (const file of data.files) {
    box.append(specFileBlock(file, !!data.serial && !!data.app_id));
  }
  setSpecButtons(!!(State.specTimer));
}

function specFileBlock(file, canRun) {
  const runnable = file.entries.filter((e) => e.kind === "scenario");
  const skipped = file.entries.filter((e) => e.kind !== "scenario").length;
  const counts = runnable.length + " scenarios" +
                 (skipped ? ", " + skipped + " placeholders" : "");
  const headBtn = el("button", {
    class: "ghost small-btn",
    text: "Run file",
    onclick: (event) => {
      event.stopPropagation();
      runSpec({file: file.path});
    },
  });
  headBtn.disabled = !canRun;

  const editFileBtn = el("button", {
    class: "ghost small-btn",
    text: "+ Scenario",
    title: "add a new scenario to this file and edit it",
    onclick: (event) => {
      event.stopPropagation();
      newScenarioInFile(file.path);
    },
  });

  const head = el("div", {class: "spec-file-head"},
    el("span", {class: "name mono", text: file.file}),
    el("span", {class: "counts", text: counts}),
    el("span", {class: "spacer"}),
    editFileBtn,
    headBtn);

  const list = el("ul", {class: "spec-scenarios"});
  for (const entry of file.entries) {
    list.append(specEntryRow(entry, file.path, canRun));
  }

  const block = el("div", {class: "spec-file" + (file.error ? " broken" : "")},
                   head, list);
  head.addEventListener("click", (event) => {
    if (event.target === headBtn) return;
    block.classList.toggle("collapsed");
  });
  return block;
}

function specEntryRow(entry, filePath, canRun) {
  const row = el("li", {class: "spec-scenario kind-" + entry.kind});
  if (entry.kind === "scenario") {
    row.append(el("span", {class: "name", text: entry.name,
                           title: entry.name}));
    row.append(el("span", {class: "counts", text: entry.step_count + " steps"}));
    const runBtn = el("button", {
      class: "ghost small-btn",
      text: "Run",
      title: "run only this scenario (--only)",
      onclick: () => runSpec({file: filePath, only: entry.name}),
    });
    runBtn.disabled = !canRun || entry.errors.length > 0;
    const editBtn = el("button", {
      class: "ghost small-btn",
      text: "Edit",
      title: "edit this scenario's steps",
      onclick: () => editScenario(filePath, entry.index),
    });
    row.append(el("span", {class: "spacer"}), editBtn, runBtn);
    for (const issue of entry.errors.slice(0, 3)) {
      row.append(el("div", {class: "entry-error mono small",
                            text: issue.path + " " + issue.message}));
    }
  } else if (entry.kind === "skipped") {
    row.append(el("span", {class: "name muted", text: entry.skipped || "-",
                           title: entry.why || ""}));
    row.append(el("span", {class: "badge subtle",
                           text: "not automated"}));
  } else if (entry.kind === "note") {
    row.append(el("span", {class: "name muted italic", text: entry.why,
                           title: entry.why}));
  } else {
    row.append(el("span", {class: "name muted", text: "(invalid entry)"}));
    for (const issue of entry.errors) {
      row.append(el("div", {class: "entry-error mono small", text: issue}));
    }
  }
  return row;
}

async function editScenario(filePath, index) {
  if (State.dirty &&
      !confirm("Discard unsaved changes currently shown in the Steps editor?")) {
    return;
  }
  let data;
  try {
    data = await api("/api/spec/file?path=" + encodeURIComponent(filePath));
  } catch (err) {
    toast(err.message, "error");
    return;
  }
  State.specDoc = data.doc;
  enterScenarioMode(data.path || filePath, index);
}

async function newScenarioInFile(filePath) {
  if (State.dirty &&
      !confirm("Discard unsaved changes currently shown in the Steps editor?")) {
    return;
  }
  let data;
  try {
    data = await api("/api/spec/file?path=" + encodeURIComponent(filePath));
    State.specDoc = data.doc;
    State.specDoc.push({name: "New scenario", steps: [{action: "launch"}]});
  } catch (err) {
    toast(err.message, "error");
    return;
  }
  enterScenarioMode(data.path || filePath, State.specDoc.length - 1);
  markDirty(true);
}

function enterScenarioMode(filePath, index) {
  Editor.mode = "scenario";
  Editor.filePath = filePath;
  Editor.entryIndex = index;
  const entry = State.specDoc[index] || {};
  $("#scenario-name").value = entry.name || "";
  syncEditorModeUI();
  updateStepsFileLabel();
  markDirty(false);
  renderTree();
  renderValidation();
  activateTab("steps");
}

async function runSpec(extra) {
  const body = Object.assign({
    settings: {
      serial: State.settings.serial,
      second_device: $("#second-device-toggle")
        ? $("#second-device-toggle").checked : !!State.settings.second_device,
      serial_2: $("#device-select-2") ? $("#device-select-2").value : "",
      app_id_2: $("#app-input-2") ? $("#app-input-2").value.trim() : "",
      activity_2: $("#activity-input-2") ? $("#activity-input-2").value.trim() : "",
      spec_app_id: $("#spec-app-id").value.trim(),
      spec_activity: $("#spec-activity").value.trim(),
    },
  }, extra);
  try {
    await api("/api/spec/run", {method: "POST", body});
    const logBox = $("#spec-log");
    logBox.hidden = false;
    logBox.innerHTML = "";
    $("#spec-report").innerHTML = "";
    $("#spec-result").textContent = "";
    $("#spec-command").textContent = "starting...";
    State.specOffset = 0;
    setSpecButtons(true);
    setRunningUI(true);
    startSpecPolling();
  } catch (err) {
    toast(err.message, "error");
  }
}

function setSpecButtons(running) {
  $("#spec-cancel").disabled = !running;
  $("#spec-run-all").disabled = running;
  $$("#spec-files button").forEach((b) => { b.disabled = running; });
}

function startSpecPolling() {
  clearInterval(State.specTimer);
  State.specTimer = setInterval(specPollOnce, 700);
  specPollOnce();
}

async function specPollOnce() {
  let status;
  try {
    status = await api("/api/run/status?since=" + State.specOffset);
  } catch (err) {
    return;
  }
  const logBox = $("#spec-log");
  logBox.hidden = false;
  for (const line of status.lines) {
    const cls = /ERROR|error:/i.test(line) ? "log-line err"
      : line.startsWith("==>") ? "log-line ok" : "log-line";
    logBox.append(el("div", {class: cls, text: line}));
  }
  if (status.lines.length) logBox.scrollTop = logBox.scrollHeight;
  State.specOffset = status.offset;
  if (status.command) $("#spec-command").textContent = status.command;

  if (!status.running && status.exit_code !== null &&
      status.exit_code !== undefined) {
    clearInterval(State.specTimer);
    State.specTimer = null;
    setSpecButtons(false);
    setRunningUI(false);
    renderSpecFinished(status);
  }
}

function renderSpecFinished(status) {
  const code = status.exit_code;
  const chip = $("#run-chip");
  if (code === 0) {
    chip.textContent = "done";
    chip.className = "badge ok";
  } else if (code === 130 || code === 143) {
    chip.textContent = "cancelled";
    chip.className = "badge warn";
  } else {
    chip.textContent = "exit " + code;
    chip.className = "badge err";
  }
  const result = $("#spec-result");
  result.style.color = code === 0 ? "var(--ok)" : "var(--err)";
  result.textContent = code === 0 ? "all executed scenarios passed"
                                  : "some scenarios failed (exit " + code + ")";
  renderSpecReport(status.spec_report);
}

function renderSpecReport(report) {
  const box = $("#spec-report");
  box.innerHTML = "";
  if (!report) return;
  if (report.error) {
    box.append(el("p", {class: "hint", text: report.error,
                        style: "color: var(--err);"}));
    return;
  }
  const s = report.summary || {};
  const chips = el("div", {class: "row report-chips"},
    el("span", {class: "badge ok mono small", text: "passed " + (s.passed || 0)}),
    el("span", {class: "badge err mono small", text: "failed " + (s.failed || 0)}),
    el("span", {class: "badge warn mono small", text: "skipped " + (s.skipped || 0)}),
    el("span", {class: "badge subtle mono small",
                text: "implemented " + (s.implemented || 0) + " / available " + (s.available || 0)}));
  box.append(chips);

  const results = report.results || [];
  const table = el("table", {class: "report-table mono small"});
  table.append(el("tr", {},
    el("th", {text: "file"}), el("th", {text: "scenario"}),
    el("th", {text: "result"}), el("th", {text: "detail"})));
  for (const r of results) {
    const failed = r.status !== "PASS";
    table.append(el("tr", {class: failed ? "fail" : ""},
      el("td", {text: r.file}),
      el("td", {text: r.name}),
      el("td", {class: failed ? "cell-err" : "cell-ok", text: r.status}),
      el("td", {class: "muted", text: r.failed_step
                ? r.failed_step + ": " + (r.error || "") : ""})));
  }
  box.append(table);

  const skipped = report.skipped || [];
  if (skipped.length) {
    const details = el("details", {},
      el("summary", {text: "skipped placeholders (" + skipped.length + ")"}));
    for (const item of skipped) {
      details.append(el("div", {class: "skip-row"},
        el("span", {class: "mono small", text: "[" + item.file + "] "}),
        el("span", {class: "small", text: item.skipped || ""}),
        item.why ? el("div", {class: "hint", text: item.why}) : null));
    }
    box.append(details);
  }
}

boot();
