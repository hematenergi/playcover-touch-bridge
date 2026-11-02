// Run with an unlocked Android showing the bridge and `adb forward tcp:19472 localabstract:chrome_devtools_remote`.
import assert from 'node:assert/strict';

const tabs = await (await fetch('http://127.0.0.1:19472/json')).json();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function connect(tab) {
  const socket = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let id = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const key = ++id;
    pending.set(key, response => response.error ? reject(Error(response.error.message)) : resolve(response.result));
    socket.send(JSON.stringify({ id: key, method, params }));
    setTimeout(() => { if (pending.delete(key)) reject(Error('Android browser timed out')); }, 5000).unref();
  });
  const evaluate = async expression => {
    const response = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (response.exceptionDetails) throw Error(response.exceptionDetails.text);
    return response.result.value;
  };
  return { socket, call, evaluate };
}

let browser;
for (const tab of tabs.filter(tab => tab.url?.startsWith('http://127.0.0.1:19470/'))) {
  const candidate = await connect(tab);
  if (await candidate.evaluate('document.visibilityState === "visible"')) { browser = candidate; break; }
  candidate.socket.close();
}
assert(browser, 'Open the bridge in Android Chrome first');
const { evaluate, call } = browser;
const original = await evaluate('JSON.stringify(barPrefs)');
async function checkBounds() {
  const bounds = JSON.parse(await evaluate('JSON.stringify({r:toolbar.getBoundingClientRect().toJSON(),w:innerWidth,h:innerHeight})'));
  assert(bounds.r.left >= 7 && bounds.r.top >= 7, 'Toolbar escaped the top/left edge');
  assert(bounds.r.right <= bounds.w - 7 && bounds.r.bottom <= bounds.h - 7, 'Toolbar escaped the bottom/right edge: ' + JSON.stringify(bounds));
}
try {
  await evaluate('barPrefs.direction="vertical";barPrefs.x=0;barPrefs.y=0;updateToolbar();saveToolbar()');
  await checkBounds();
  const before = JSON.parse(await evaluate('JSON.stringify({b:window.playTouchDiagnostics().sentBatches,r:grab.getBoundingClientRect().toJSON(),w:innerWidth,h:innerHeight})'));
  const point = { x: before.r.x + before.r.width / 2, y: before.r.y + before.r.height / 2, id: 91 };
  await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point] });
  await call('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ ...point, x: before.w - 15, y: before.h - 15 }] });
  await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await pause(80);
  const moved = JSON.parse(await evaluate('JSON.stringify(window.playTouchDiagnostics())'));
  assert(moved.toolbar.x > 0.5 && moved.toolbar.y > 0.5, 'Handle drag did not move the toolbar');
  assert.equal(moved.sentBatches, before.b, 'Dragging the toolbar leaked input into the game');
  await checkBounds();
  await evaluate('document.querySelector("#directionButton").click()');
  assert.equal(await evaluate('barPrefs.direction'), 'horizontal');
  await checkBounds();
  await evaluate('document.querySelector("#barOpacity").value=70;document.querySelector("#barOpacity").dispatchEvent(new Event("input"));document.querySelector("#barIdleOpacity").value=15;document.querySelector("#barIdleOpacity").dispatchEvent(new Event("input"));barPrefs.autoFade=true;updateToolbar();saveToolbar()');
  await pause(2400);
  assert.equal(await evaluate('toolbar.classList.contains("idle")'), true, 'Idle fade did not activate');
  assert(Math.abs(Number(await evaluate('getComputedStyle(toolbar).opacity')) - .15) < .01, 'Idle opacity was not applied');
  await evaluate('barPrefs.autoFade=false;updateToolbar();saveToolbar();toolbar.classList.add("dim")');
  await pause(240);
  assert(Math.abs(Number(await evaluate('getComputedStyle(toolbar).opacity')) - .7) < .01, 'Disabling fade still dimmed the toolbar');
  await evaluate('toolbar.classList.remove("dim");barPrefs.autoFade=true;updateToolbar();saveToolbar()');
  const saved = await evaluate('JSON.stringify(barPrefs)');
  await call('Page.reload', { ignoreCache: true });
  await pause(1000);
  assert.equal(await evaluate('JSON.stringify(barPrefs)'), saved, 'Toolbar preferences did not survive reload');
  await checkBounds();
  assert.equal(await evaluate('window.playTouchDiagnostics().renderer'), 'image', 'Video renderer changed');
  console.log('PASS: real touch drag, game-input isolation, both directions, viewport bounds, fade toggle/opacity, and persistence.');
} finally {
  await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }).catch(() => {});
  await evaluate(`barPrefs=${original};updateToolbar();saveToolbar()`).catch(() => {});
  browser.socket.close();
}
