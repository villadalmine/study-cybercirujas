/**
 * Drive the study bot's phase-2 loop outside a browser.
 *
 * The loop in teach/web/index.html is the only part of the bot that cannot be
 * checked by `make verify`: it runs in the student's browser, calls
 * openrouter.ai with their key, and spends real money per turn. So it used to
 * be verified by reading it — which is how the Models page shipped with four
 * defects that one render would have caught.
 *
 * This loads the page's OWN functions, stubs just enough DOM to run them, and
 * drives them against a local API and a real model. What it proves:
 *
 *   - the model is shown the index and asks for topics through the tools
 *   - the caps bind (at most BOT_MAX_TOPICS fetched, BOT_MAX_ROUNDS turns)
 *   - the answer arrives, and names which topics it used
 *   - the two-round-trip fallback works for a model that cannot drive a tool
 *
 * SPENDS THE BOT KEY, never the subscription. One question costs about a cent
 * on gpt-5-mini. Manual on purpose: nothing that spends runs in `make verify`.
 *
 *   make serve &                                    # or uvicorn on 8000
 *   node scripts/bot_loop_check.js
 *   node scripts/bot_loop_check.js --model anthropic/claude-haiku-4.5
 *   node scripts/bot_loop_check.js --fallback       # force the no-tools path
 *   node scripts/bot_loop_check.js --path kubernetes  # phase 3, a whole career
 *   node scripts/bot_loop_check.js --api http://localhost:8899
 */
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..');
const arg = (name, fallback) => {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const MODEL = arg('model', 'openai/gpt-5-mini');
const API = arg('api', 'http://localhost:8000');
const CERT = arg('cert', 'lpi-010-160');
const LANGUAGE = arg('lang', 'en');
const FALLBACK = process.argv.includes('--fallback');
const PATH_SLUG = arg('path', null);
const QUESTION = arg('q',
  'Which topics of this certification deal with users, permissions and file ' +
  'ownership, and what is the single file that stores local user accounts?');

// The bot's own OpenRouter key, kept apart from the translation key so a check
// can never spend the working budget. Same variable scripts/probe_models.py uses.
const line = fs.readFileSync(path.join(REPO, '.env'), 'utf8').split('\n')
  .find((l) => l.startsWith('LITELLM_API_KEY_BOT='));
if (!line) {
  console.error('LITELLM_API_KEY_BOT is not in .env — see scripts/probe_models.py.');
  process.exit(2);
}
const KEY = line.split('=')[1].trim();

// Just enough DOM for the page's functions to run unmodified. Anything the loop
// does not touch stays a stub; anything it reads is a real control with the
// value a student would have set.
const els = {
  bm: { value: MODEL, selectedOptions: [{ dataset: { t: 'always', off: '' } }] },
  be: { value: '' }, bx: { value: 'content' }, bh: { checked: false },
  bc: { value: CERT }, bt: { value: '' }, bq: { value: '' },
  bused: { textContent: '' }, best: { textContent: '' },
  bnow: { innerHTML: '' },
  bout: { innerHTML: '', insertAdjacentHTML() {} },
  content: { innerHTML: '' },
};
globalThis.document = {
  getElementById: (id) => els[id] || (els[id] = { innerHTML: '', textContent: '', value: '' }),
  querySelector: () => ({ textContent: '' }),
  documentElement: {}, addEventListener: () => {},
};
globalThis.window = { scrollTo: () => {}, addEventListener: () => {} };
globalThis.localStorage = { getItem: (k) => (k === 'or_key' ? KEY : null), setItem: () => {} };
globalThis.location = { origin: 'https://study.cybercirujas.club' };

const page = fs.readFileSync(path.join(REPO, 'teach/web/index.html'), 'utf8');
const script = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n')
  // the boot block would render the landing page; this harness drives instead
  .replace(/\(async \(\) => \{\s*document\.documentElement\.lang[\s\S]*$/, '')
  // point the page's own api() at the API under test, touching nothing else
  .replace('const api = async (path, options) => {',
           'const api = async (path, options) => { if (globalThis.__api) return globalThis.__api(path);');

eval(script + `
  globalThis.__run = async () => {
    LANG = ${JSON.stringify(LANGUAGE)};
    globalThis.__api = async (p) => {
      const r = await fetch(${JSON.stringify(API)} + p);
      if (!r.ok) throw new Error(p + ' -> HTTP ' + r.status);
      return r.json();
    };
    BOT_MODELS = await globalThis.__api('/api/models');
    if (${FALLBACK}) {
      for (const tier of Object.values(BOT_MODELS.tiers || {})) {
        for (const m of tier) m.tools = 'ignored';
      }
    }
    const picked = botAll().find((m) => m.id === ${JSON.stringify(MODEL)});
    if (!picked) throw new Error('${MODEL} is not in models.yaml');
    const slug = ${JSON.stringify(PATH_SLUG)};
    const answer = slug
      ? await botAskCareer(KEY, slug, ${JSON.stringify(QUESTION)}, 'plan')
      : await botAskSpanning(KEY, ${JSON.stringify(CERT)}, ${JSON.stringify(QUESTION)}, null);
    return { answer,
             tools: picked.tools,
             certs: slug ? BOT_MAX_CERTS : null,
             // the page's own caps, read from inside the eval scope where they
             // are declared, so this checks the real numbers and not a copy
             caps: { topics: BOT_MAX_TOPICS, rounds: BOT_MAX_ROUNDS,
                     certs: BOT_MAX_CERTS } };
  };
`);

(async () => {
  const started = Date.now();
  const { answer, tools, caps } = await globalThis.__run();
  const loaded = (answer.note || '').replace(/^[^:]*:\s*/, '') || '(none)';
  const count = loaded === '(none)' ? 0 : loaded.split(',').length;
  console.log(`model     ${MODEL}  (tools=${FALLBACK ? 'forced off' : tools})`);
  console.log(`path      ${PATH_SLUG ? `career: ${PATH_SLUG}`
                : FALLBACK || tools !== 'calls' ? 'two round trips' : 'tool calling'}`);
  console.log(`${PATH_SLUG ? 'certs   ' : 'topics  '}  ${loaded}`);
  console.log(`tokens    ${els.bused.textContent}   ${((Date.now() - started) / 1000).toFixed(1)}s`);
  console.log(`answer    ${(answer.text || '').replace(/\n+/g, ' ').slice(0, 300)}`);
  if (!answer.text) { console.error('\nFAIL: the loop produced no answer.'); process.exit(1); }
  const cap = PATH_SLUG ? caps.certs : caps.topics;
  const unit = PATH_SLUG ? 'certifications' : 'topics';
  if (count > cap) {
    console.error(`\nFAIL: read ${count} ${unit}, cap is ${cap}.`);
    process.exit(1);
  }
  console.log(`\nOK: the loop answered, and the cap held `
              + `(${count}/${cap} ${unit}${PATH_SLUG ? '' : `, at most ${caps.rounds} rounds`}).`);
})().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
