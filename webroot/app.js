const BIN = "/data/adb/modules/block_samsung_ota/system/bin/blockota";

const views = {
  status: document.getElementById("view-status"),
  packages: document.getElementById("view-packages"),
  settings: document.getElementById("view-settings")
};

function exec(command) {
  if (typeof ksu === "undefined" || !ksu.exec) {
    return Promise.resolve({
      errno: 1,
      stdout: "",
      stderr: "Open this page from KernelSU, APatch, or KsuWebUI."
    });
  }
  const callback = "cb_" + Date.now() + "_" + Math.random().toString(16).slice(2);
  return new Promise((resolve) => {
    window[callback] = (errno, stdout, stderr) => {
      delete window[callback];
      resolve({ errno: Number(errno), stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      ksu.exec(command, "{}", callback);
    } catch (error) {
      delete window[callback];
      resolve({ errno: 1, stdout: "", stderr: String(error) });
    }
  });
}

function validPackage(name) {
  return /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(name);
}

function toast(message) {
  if (typeof ksu !== "undefined" && ksu.toast) ksu.toast(message);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function stateLabel(state) {
  if (state === "disabled") return "Blocked";
  if (state === "enabled") return "Still enabled";
  if (state === "absent") return "Not installed";
  return state || "Unknown";
}

function packageRow(item, buttons) {
  const row = el("div", "row");
  const name = el("div", "name", item.name);
  const side = el("div", "actions");
  side.appendChild(el("span", "state " + item.state, stateLabel(item.state)));
  buttons.forEach((button) => side.appendChild(button));
  row.append(name, side);
  return row;
}

function actionButton(label, className, onClick) {
  const button = el("button", className, label);
  button.type = "button";
  button.addEventListener("click", onClick);
  return button;
}

async function run(command) {
  const result = await exec(command);
  if (result.errno !== 0) {
    throw new Error((result.stdout || result.stderr || "Command failed").trim());
  }
  return result.stdout;
}

async function refresh() {
  const result = await exec(BIN + " ui");
  if (result.errno !== 0) {
    showError(result.stderr || result.stdout || "Could not read module status.");
    return;
  }
  let data;
  try {
    data = JSON.parse(result.stdout);
  } catch (error) {
    showError("Status was not valid. " + result.stdout.slice(0, 180));
    return;
  }
  showError("");
  render(data);
}

function showError(message) {
  const box = document.getElementById("error");
  box.textContent = message;
  box.classList.toggle("hidden", !message);
}

function render(data) {
  document.getElementById("version").textContent = (data.version || "module") + " · " + (data.model || "unknown device");
  renderStatus(data);
  renderPackages(data);
  renderSettings(data);
}

function renderStatus(data) {
  const root = views.status;
  root.replaceChildren();
  const headlines = {
    blocking: ["blocking", "Samsung updates are blocked on this phone."],
    paused: ["paused", "Blocking is off. Update packages this module changed have been restored."],
    incomplete: ["incomplete", "Blocking is on, but an update package is still enabled or the firewall rule is missing."],
    "wrong-device": ["wrong-device", "This module only changes Samsung phones. Nothing was disabled."]
  };
  const headline = headlines[data.summary] || headlines.incomplete;
  root.appendChild(el("div", "banner " + headline[0], headline[1]));

  const info = el("div", "card");
  info.appendChild(el("h2", null, "This phone"));
  [
    ["Brand", data.brand],
    ["Model", data.model],
    ["Android", data.android],
    ["One UI", data.oneui || "none"],
    ["Firewall rule", data.ifw],
    ["Software update screen", data.resolvedActivity || "none found"]
  ].forEach((pair) => {
    const line = el("div", "meta");
    line.append(el("span", null, pair[0]), el("span", "state", pair[1] || "unknown"));
    info.appendChild(line);
  });
  root.appendChild(info);

  const list = el("div", "card");
  list.appendChild(el("h2", null, "Built-in update packages"));
  (data.packages || []).forEach((item) => list.appendChild(packageRow(item, [])));
  root.appendChild(list);
}

function renderPackages(data) {
  const root = views.packages;
  root.replaceChildren();

  const missedCard = el("div", "card");
  missedCard.appendChild(el("h2", null, "Possible packages not in the built-in list"));
  const missed = data.missed || [];
  if (!missed.length) {
    missedCard.appendChild(el("p", "empty", "No extra updater-like packages found."));
  }
  missed.forEach((item) => {
    missedCard.appendChild(packageRow(item, [
      actionButton("Block", "primary", () => changePackage("blacklist-add", item.name)),
      actionButton("Not an updater", null, () => changePackage("ignore-add", item.name))
    ]));
  });
  root.appendChild(missedCard);

  const extraCard = el("div", "card");
  extraCard.appendChild(el("h2", null, "Extra packages you blocked"));
  const extra = data.blockedExtra || [];
  if (!extra.length) extraCard.appendChild(el("p", "empty", "None yet."));
  extra.forEach((item) => {
    extraCard.appendChild(packageRow(item, [
      actionButton("Unblock", "danger", () => changePackage("blacklist-remove", item.name))
    ]));
  });
  root.appendChild(extraCard);

  const addCard = el("div", "card");
  addCard.appendChild(el("h2", null, "Block a package by name"));
  const input = document.createElement("input");
  input.placeholder = "com.example.update";
  input.autocomplete = "off";
  input.spellcheck = false;
  const add = actionButton("Block this package", "primary", async () => {
    if (!validPackage(input.value.trim())) {
      showError("Enter a package name like com.example.update.");
      return;
    }
    await changePackage("blacklist-add", input.value.trim());
    input.value = "";
  });
  addCard.append(input, add);
  root.appendChild(addCard);

  const protectedMatches = data.protectedMatches || [];
  if (protectedMatches.length) {
    const note = el("div", "card");
    note.appendChild(el("h2", null, "Left alone on purpose"));
    note.appendChild(el("p", "empty", "These matched the scan, and the module will not disable them."));
    protectedMatches.forEach((item) => note.appendChild(packageRow(item, [])));
    root.appendChild(note);
  }
}

function renderSettings(data) {
  const root = views.settings;
  root.replaceChildren();
  const card = el("div", "card");
  const row = el("div", "switch");
  const label = el("div");
  label.append(
    el("strong", null, "Block Samsung updates"),
    el("div", "sub", "Off restores every package this module disabled and removes its firewall rule.")
  );
  const toggle = document.createElement("input");
  toggle.type = "checkbox";
  toggle.checked = !data.paused;
  toggle.addEventListener("change", async () => {
    try {
      if (toggle.checked) {
        await run(BIN + " enforce");
        toast("Blocking is on");
      } else if (window.confirm("Turn blocking off and restore the update packages?")) {
        await run(BIN + " restore");
        toast("Blocking is off");
      } else {
        toggle.checked = true;
        return;
      }
      await refresh();
    } catch (error) {
      showError(error.message);
      toggle.checked = !data.paused;
    }
  });
  row.append(label, toggle);
  card.appendChild(row);
  root.appendChild(card);

  const tools = el("div", "card stack");
  tools.appendChild(el("h2", null, "Check again"));
  tools.appendChild(actionButton("Refresh status", "primary", refresh));
  tools.appendChild(actionButton("Show recent log", null, async () => {
    const text = await exec(BIN + " log");
    logBox.textContent = (text.stdout || text.stderr || "No log yet.").trim();
  }));
  const logBox = el("pre", null, "");
  tools.appendChild(logBox);
  root.appendChild(tools);
}

async function changePackage(action, name) {
  if (!validPackage(name)) {
    showError("That package name cannot be used.");
    return;
  }
  try {
    await run(BIN + " " + action + " " + name);
    toast(action === "blacklist-add" ? "Package blocked" : "List updated");
    await refresh();
  } catch (error) {
    showError(error.message);
  }
}

document.getElementById("tab-status").addEventListener("click", () => showTab("status"));
document.getElementById("tab-packages").addEventListener("click", () => showTab("packages"));
document.getElementById("tab-settings").addEventListener("click", () => showTab("settings"));

function showTab(name) {
  Object.keys(views).forEach((key) => {
    views[key].classList.toggle("hidden", key !== name);
    document.getElementById("tab-" + key).classList.toggle("active", key === name);
  });
}

if (typeof ksu !== "undefined" && ksu.fullScreen) ksu.fullScreen(true);
refresh();
