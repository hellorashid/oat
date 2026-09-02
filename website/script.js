const oatWindow = document.getElementById("oatWindow");
const oatToggle = document.getElementById("oatToggle");
const statusTime = document.getElementById("statusTime");
const statusDot = document.getElementById("statusDot");
const recordButton = document.getElementById("recordButton");
const recordLabel = document.getElementById("recordLabel");
const trayRecordLabel = document.getElementById("trayRecordLabel");
const micMeter = document.getElementById("micMeter");
const library = document.getElementById("library");
const emptyState = document.getElementById("emptyState");
const recordingsPane = document.getElementById("recordingsPane");
const settingsPane = document.getElementById("settingsPane");
const tabRecordings = document.getElementById("tabRecordings");
const tabSettings = document.getElementById("tabSettings");
const photoCreditToggle = document.getElementById("photoCreditToggle");
const photoCreditPopover = document.getElementById("photoCreditPopover");

function hoursAgo(hours) {
  return new Date(Date.now() - hours * 60 * 60 * 1000);
}

function yesterdayAt(hours, minutes) {
  const date = new Date();
  date.setDate(date.getDate() - 1);
  date.setHours(hours, minutes, 0, 0);
  return date;
}

const state = {
  windowOpen: true,
  activeMenu: null,
  isPhotoCreditOpen: false,
  tab: "recordings",
  recording: false,
  elapsedMs: 0,
  recordingId: null,
  recordings: [
    {
      id: "seed-standup",
      createdAt: hoursAgo(3).toISOString(),
      durationSeconds: 47 * 60 + 22,
      status: "transcribed",
      seed: 11,
    },
    {
      id: "seed-review",
      createdAt: yesterdayAt(14, 10).toISOString(),
      durationSeconds: 62 * 60 + 8,
      status: "transcribed",
      seed: 23,
    },
  ],
};

let recordTimer = null;
let nextId = 1;

function formatStatusTime(date) {
  const monthDay = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
  }).format(date);
  const clock = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(date);

  return `${monthDay} ${clock}`;
}

function formatElapsed(ms) {
  const total = Math.floor(ms / 1000);
  const minutes = String(Math.floor(total / 60)).padStart(2, "0");
  const seconds = String(total % 60).padStart(2, "0");
  return `${minutes}:${seconds}`;
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(total / 60);
  const rest = String(total % 60).padStart(2, "0");
  return `${minutes}m ${rest}s`;
}

function formatTitle(iso) {
  const date = new Date(iso);
  const day = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(date);
  const time = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(date);

  return `${day} at ${time}`;
}

function waveformPath(seed, mirror) {
  const count = 18;
  const points = [];
  let value = seed * 17 + 3;

  for (let index = 0; index <= count; index += 1) {
    value = (value * 16807) % 2147483647;
    const t = index / count;
    const envelope = Math.sin(Math.PI * t);
    const noise = (value % 100) / 100;
    const rise = (0.18 + envelope * (0.55 + noise * 0.35)) * (mirror ? 1 : -1);
    const x = (index / count) * 160;
    const y = 18 + rise * 16;
    points.push(`${index === 0 ? "M" : "L"}${x.toFixed(1)} ${y.toFixed(1)}`);
  }

  points.push("L160 18 L0 18 Z");
  return points.join(" ");
}

function closeMenus() {
  state.activeMenu = null;
  document.querySelectorAll(".menu-slot.is-open").forEach((slot) => {
    slot.classList.remove("is-open");
  });
}

function openMenu(menuName) {
  closeMenus();
  state.activeMenu = menuName;
  const slot = document
    .querySelector(`[data-menu-trigger="${menuName}"]`)
    ?.closest(".menu-slot");

  if (slot) {
    slot.classList.add("is-open");
  }
}

function toggleMenu(menuName) {
  if (state.activeMenu === menuName) {
    closeMenus();
    return;
  }

  openMenu(menuName);
}

function closePhotoCredit() {
  state.isPhotoCreditOpen = false;
}

function liveRecording() {
  return state.recordings.find((item) => item.id === state.recordingId);
}

function startRecording() {
  const item = {
    id: `rec-${nextId}`,
    createdAt: new Date().toISOString(),
    durationSeconds: 0,
    status: "recording",
    seed: 30 + nextId * 7,
  };
  nextId += 1;
  state.recordings.unshift(item);
  state.recording = true;
  state.elapsedMs = 0;
  state.recordingId = item.id;
  state.tab = "recordings";
  state.windowOpen = true;

  if (recordTimer) {
    window.clearInterval(recordTimer);
  }
  recordTimer = window.setInterval(() => {
    state.elapsedMs += 1000;
    const current = liveRecording();
    if (current) {
      current.durationSeconds = Math.floor(state.elapsedMs / 1000);
    }
    renderTimer();
  }, 1000);
}

function stopRecording() {
  const current = liveRecording();
  if (current) {
    current.durationSeconds = Math.max(1, Math.floor(state.elapsedMs / 1000));
    current.status = "transcribed";
  }

  state.recording = false;
  state.elapsedMs = 0;
  state.recordingId = null;
  if (recordTimer) {
    window.clearInterval(recordTimer);
    recordTimer = null;
  }
}

function deleteRecording(id) {
  if (id === state.recordingId) {
    return;
  }
  state.recordings = state.recordings.filter((item) => item.id !== id);
}

function applyAction(action, dataset) {
  switch (action) {
    case "toggle-record":
      if (state.recording) {
        stopRecording();
      } else {
        startRecording();
      }
      break;
    case "delete-recording":
      deleteRecording(dataset.id);
      break;
    case "open-window":
      state.windowOpen = true;
      state.tab = "recordings";
      break;
    case "open-settings":
      state.windowOpen = true;
      state.tab = "settings";
      break;
    case "open-about":
      state.windowOpen = true;
      state.tab = "settings";
      window.requestAnimationFrame(() => {
        settingsPane.scrollTop = 0;
      });
      break;
    case "quit-oat":
      state.windowOpen = false;
      if (state.recording) {
        stopRecording();
      }
      break;
    case "show-tab":
      state.tab = dataset.tab || "recordings";
      state.windowOpen = true;
      break;
    case "toggle-photo-credit":
      state.isPhotoCreditOpen = !state.isPhotoCreditOpen;
      break;
    default:
      break;
  }

  render();
}

function renderClock() {
  statusTime.textContent = formatStatusTime(new Date());
}

function renderLibrary() {
  const isEmpty = state.recordings.length === 0;
  library.hidden = isEmpty;
  emptyState.hidden = !isEmpty;
  library.replaceChildren();

  if (isEmpty) {
    return;
  }

  state.recordings.forEach((item) => {
    const isLive = item.id === state.recordingId;
    const article = document.createElement("article");
    article.className = "recording";
    article.dataset.recordingId = item.id;
    article.innerHTML = `
      <div class="recording-head">
        <h2 class="recording-title"></h2>
        <p class="recording-duration"></p>
      </div>
      <div class="recording-row">
        <div class="recording-actions">
          <button class="icon-btn" type="button" aria-label="Play">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M8.4 6.2v11.6l9.8-5.8-9.8-5.8Z" fill="currentColor" />
            </svg>
          </button>
          <button class="transcript-btn" type="button">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M7 3.8h7.2L18.5 8v12.2H7V3.8Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" />
              <path d="M14 3.8V8h4.4" fill="none" stroke="currentColor" stroke-width="1.5" />
              <path d="M9.4 12.2h5.4M9.4 15.2h3.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
            </svg>
            Transcript
            <svg class="transcript-chevron" viewBox="0 0 24 24" aria-hidden="true">
              <path d="m7 9.5 5 5 5-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
          <button class="icon-btn icon-btn--danger" type="button" aria-label="Delete" data-action="delete-recording" data-id="">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M9 4.6h6M5.5 7h13M8.2 7l.7 12.2h6.2L15.8 7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
        </div>
        <svg class="waveform" viewBox="0 0 160 36" preserveAspectRatio="none" aria-hidden="true">
          <path class="waveform-line" d="M0 18h160" />
          <path class="waveform-fill" d="" />
          <path class="waveform-fill" d="" />
        </svg>
      </div>
      <p class="recording-status" hidden></p>
    `;

    article.querySelector(".recording-title").textContent = formatTitle(item.createdAt);
    article.querySelector(".recording-duration").textContent = formatDuration(item.durationSeconds);
    const status = article.querySelector(".recording-status");
    if (isLive) {
      status.hidden = false;
      status.textContent = "recording";
      status.classList.add("is-live");
    } else {
      status.hidden = true;
    }

    const deleteButton = article.querySelector("[data-action='delete-recording']");
    deleteButton.dataset.id = item.id;
    deleteButton.disabled = isLive;

    const waveform = article.querySelector(".waveform");
    if (isLive) {
      waveform.hidden = true;
    } else {
      const fills = article.querySelectorAll(".waveform-fill");
      fills[0].setAttribute("d", waveformPath(item.seed, false));
      fills[1].setAttribute("d", waveformPath(item.seed, true));
    }

    library.appendChild(article);
  });
}

function renderTimer() {
  recordButton.classList.toggle("is-live", state.recording);
  recordButton.setAttribute(
    "aria-label",
    state.recording ? "Stop recording" : "Start recording",
  );
  recordLabel.textContent = state.recording
    ? formatElapsed(state.elapsedMs)
    : "Start recording";
  trayRecordLabel.textContent = state.recording ? "Stop Recording" : "Start Recording";
  micMeter.hidden = !state.recording;
  statusDot.hidden = !state.recording;

  const live = library.querySelector(
    `[data-recording-id="${state.recordingId}"] .recording-duration`,
  );
  if (live) {
    live.textContent = formatDuration(Math.floor(state.elapsedMs / 1000));
  }
}

function render() {
  oatWindow.classList.toggle("is-hidden", !state.windowOpen);
  oatToggle.setAttribute("aria-expanded", String(state.activeMenu === "tray"));

  photoCreditToggle.setAttribute("aria-expanded", String(state.isPhotoCreditOpen));
  photoCreditPopover.hidden = !state.isPhotoCreditOpen;

  const recordingsActive = state.tab === "recordings";
  recordingsPane.hidden = !recordingsActive;
  settingsPane.hidden = recordingsActive;
  tabRecordings.classList.toggle("is-active", recordingsActive);
  tabSettings.classList.toggle("is-active", !recordingsActive);
  tabRecordings.setAttribute("aria-selected", String(recordingsActive));
  tabSettings.setAttribute("aria-selected", String(!recordingsActive));

  renderLibrary();
  renderTimer();
  renderClock();
}

document.addEventListener("click", (event) => {
  const target = event.target;

  if (!(target instanceof Element)) {
    return;
  }

  const trigger = target.closest("[data-menu-trigger]");
  if (trigger) {
    if (state.isPhotoCreditOpen) {
      closePhotoCredit();
    }
    toggleMenu(trigger.dataset.menuTrigger);
    render();
    return;
  }

  const actionElement = target.closest("[data-action]");
  if (actionElement) {
    if (actionElement.disabled) {
      return;
    }
    if (!actionElement.closest("#photoCredit") && state.isPhotoCreditOpen) {
      closePhotoCredit();
    }
    applyAction(actionElement.dataset.action, actionElement.dataset);
    closeMenus();
    return;
  }

  const linkElement = target.closest(".menu-entry[href]");
  if (linkElement) {
    closeMenus();
    return;
  }

  let shouldRender = false;

  if (!target.closest("[data-menu-root]") && state.activeMenu) {
    closeMenus();
    shouldRender = true;
  }

  if (!target.closest("#photoCredit") && state.isPhotoCreditOpen) {
    closePhotoCredit();
    shouldRender = true;
  }

  if (shouldRender) {
    render();
  }
});

window.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeMenus();
    closePhotoCredit();
    render();
    return;
  }

  if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) {
    return;
  }

  if (event.key === "r") {
    event.preventDefault();
    applyAction("toggle-record", {});
  }

  if (event.key === "q") {
    event.preventDefault();
    applyAction("quit-oat", {});
  }
});

render();
window.setInterval(renderClock, 30000);
