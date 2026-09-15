/**
 * Ask the study bot a question in a REAL browser, through the button.
 *
 * `bot_loop_check.js` drives the page's functions directly. That is useful and
 * it is not enough: it calls `botAskSpanning` and `botAskCareer` itself, so it
 * never goes through `botAsk` — and on 2026-09-15 `botAsk` referred to a
 * variable that did not exist, every question in production died with
 * "path is not defined", and the function-level harness reported everything
 * green. A rename had landed in the wrong function and nothing that ran the
 * actual entry point was watching.
 *
 * So this one starts Chromium, loads the page, sets the key the way a student
 * does, clicks through the controls, and reads what lands on screen. It costs
 * a real question per shape on the bot's key — a cent or two — and it is the
 * only check here that would have caught that bug.
 *
 *   chromium-browser --headless --disable-gpu --no-sandbox \
 *     --remote-debugging-port=9222 about:blank &
 *   node scripts/bot_browser_check.js                       # against production
 *   node scripts/bot_browser_check.js --url http://localhost:8000/
 *   node scripts/bot_browser_check.js --shape topic|cert|career
 */
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const URL_ = arg('url', 'https://study.cybercirujas.club/');
const ONLY = arg('shape', null);
const PORT = arg('port', '9222');

const line = fs.readFileSync(path.join(REPO, '.env'), 'utf8').split('\n')
  .find((l) => l.startsWith('LITELLM_API_KEY_BOT='));
if (!line) { console.error('LITELLM_API_KEY_BOT is not in .env'); process.exit(2); }
const KEY = line.split('=')[1].trim();

// The three shapes a student can ask in, named by what they leave empty.
const SHAPES = [
  { name: 'topic',  cert: 'lpi-010-160', topic: '5.2',
    q: 'Which file stores local user accounts?', expect: /etc\/passwd/ },
  { name: 'cert',   cert: 'lpi-010-160', topic: '',
    q: 'Which topics cover users and file permissions?', expect: /5\.\d/ },
  { name: 'career', cert: 'path:kubernetes', topic: '',
    q: 'What should I study first?', expect: /KCNA|kcna/ },
];

async function connect() {
  const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
  const page = list.find((t) => t.type === 'page');
  if (!page) throw new Error('no page target — is Chromium running with --remote-debugging-port?');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  const errors = [];
  await new Promise((r, x) => { ws.addEventListener('open', r); ws.addEventListener('error', x); });
  ws.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
    // A page error must fail this check. The bug it exists for surfaced as a
    // caught exception rendered as an "OpenRouter error", so the on-screen text
    // is checked too — an error the page swallows is still an error.
    if (m.method === 'Runtime.exceptionThrown') {
      errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    }
  });
  const send = (method, params = {}) => new Promise((r) => {
    pending.set(++id, r); ws.send(JSON.stringify({ id, method, params }));
  });
  await send('Runtime.enable');
  await send('Page.enable');
  const evaluate = async (expression) => (await send('Runtime.evaluate',
    { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
  return { send, evaluate, errors, close: () => ws.close() };
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const { send, evaluate, errors, close } = await connect();
  let failed = 0;

  for (const shape of SHAPES.filter((s) => !ONLY || s.name === ONLY)) {
    await send('Page.navigate', { url: URL_ });
    await wait(6000);
    await evaluate(`localStorage.setItem('or_key', ${JSON.stringify(KEY)})`);
    await evaluate('go(showBot)');
    await wait(3000);
    await evaluate(`(() => { const c = document.getElementById('bc');
      c.value = ${JSON.stringify(shape.cert)}; c.onchange(); })()`);
    await wait(2500);
    await evaluate(`(() => { const t = document.getElementById('bt');
      t.value = ${JSON.stringify(shape.topic)}; if (t.onchange) t.onchange();
      document.getElementById('bq').value = ${JSON.stringify(shape.q)}; })()`);
    await evaluate('botAsk()');            // the button, not the internals
    await wait(shape.name === 'career' ? 150000 : 60000);

    const text = await evaluate(
      `document.getElementById('bout').textContent.replace(/\\s+/g, ' ')`) || '';
    const answered = shape.expect.test(text);
    const errored = /error/i.test(text) || errors.length;
    console.log(`${shape.name.padEnd(7)} ${answered && !errored ? 'OK  ' : 'FAIL'} ${text.slice(0, 150)}`);
    if (!answered || errored) {
      failed += 1;
      if (errors.length) console.log(`        page errors: ${errors.slice(0, 3).join(' | ')}`);
      errors.length = 0;
    }
  }

  close();
  if (failed) { console.error(`\n${failed} shape(s) failed.`); process.exit(1); }
  console.log('\nOK: every shape answered through the real page.');
})().catch((e) => { console.error('DRIVER FAILED:', e.message); process.exit(1); });
