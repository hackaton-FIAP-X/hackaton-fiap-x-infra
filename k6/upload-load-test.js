// PLT-10 — prova com numero que o sistema nao perde requisicao em pico.
//
// 1. setup:    cria um usuario descartavel e faz login (1 login so, para nao
//              esbarrar no rate limit de 10/min da AUTH-6).
// 2. cenario:  N uploads SIMULTANEOS (default 50) — um por VU, todos juntos.
// 3. teardown: consulta a API e confere que todo upload aceito (202) esta
//              persistido. Com WAIT_FOR_PROCESSING=true, espera ainda cada video
//              chegar a COMPLETED — "total processado = total enviado".
//
// Uso:
//   k6 run k6/upload-load-test.js
//   k6 run -e UPLOADS=100 -e WAIT_FOR_PROCESSING=true k6/upload-load-test.js
//   make load
//
// Relatorio: docs/load/ (JSON completo + resumo em texto).

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost';
const UPLOADS = parseInt(__ENV.UPLOADS || '50', 10);
const WAIT_FOR_PROCESSING = (__ENV.WAIT_FOR_PROCESSING || 'false') === 'true';
const PROCESSING_TIMEOUT_S = parseInt(__ENV.PROCESSING_TIMEOUT_S || '600', 10);
// Latencia NAO e criterio do PLT-10 (o requisito e nao perder requisicao). O
// "menos de 2 segundos" da VID-3 vale para um upload isolado, nao para um pico
// de 50 simultaneos. Fica opcional: -e P95_MAX_MS=2000 transforma em trava.
const P95_MAX_MS = __ENV.P95_MAX_MS ? parseInt(__ENV.P95_MAX_MS, 10) : null;

// open() so funciona no init context
const VIDEO = open('./fixtures/sample-3s.mp4', 'b');

const uploadsAccepted = new Counter('uploads_accepted');
const uploadsRejected = new Counter('uploads_rejected');
const requestsLost = new Counter('requests_lost');
const videosNotCompleted = new Counter('videos_not_completed');

export const options = {
  setupTimeout: '60s',
  teardownTimeout: `${PROCESSING_TIMEOUT_S + 60}s`,
  scenarios: {
    pico_de_uploads: {
      // cada VU faz exatamente 1 upload e todos disparam juntos
      executor: 'per-vu-iterations',
      vus: UPLOADS,
      iterations: 1,
      maxDuration: '5m',
    },
  },
  thresholds: {
    // nenhum upload recusado e nenhum aceito sumido — o requisito do enunciado
    uploads_rejected: ['count==0'],
    requests_lost: ['count==0'],
    videos_not_completed: ['count==0'],
    // sempre reportado no resumo; so trava o teste se P95_MAX_MS for informado
    'http_req_duration{name:upload}': P95_MAX_MS ? [`p(95)<${P95_MAX_MS}`] : ['p(95)>=0'],
  },
};

function json(res) {
  try { return res.json(); } catch (_) { return null; }
}

export function setup() {
  const email = `k6-${Date.now()}-${Math.floor(Math.random() * 1e6)}@fiapx.local`;
  const password = 'k6-load-Pass-123';
  const headers = { 'Content-Type': 'application/json' };

  const reg = http.post(`${BASE_URL}/auth/register`,
    JSON.stringify({ name: 'k6 load', email, password }), { headers, tags: { name: 'register' } });
  if (reg.status !== 201) fail(`register falhou: ${reg.status} ${reg.body}`);

  const login = http.post(`${BASE_URL}/auth/login`,
    JSON.stringify({ email, password }), { headers, tags: { name: 'login' } });
  const token = login.status === 200 && json(login) ? json(login).token : null;
  if (!token) fail(`login falhou: ${login.status} ${login.body}`);

  console.log(`usuario ${email} | ${UPLOADS} uploads simultaneos em ${BASE_URL}`);
  return { token };
}

export default function (data) {
  const vu = exec.vu.idInTest;
  const res = http.post(
    `${BASE_URL}/videos`,
    { file: http.file(VIDEO, `pico-${vu}.mp4`, 'video/mp4') },
    { headers: { Authorization: `Bearer ${data.token}` }, tags: { name: 'upload' }, timeout: '60s' },
  );
  const body = json(res);
  const ok = check(res, {
    'upload -> 202': (r) => r.status === 202,
    'upload devolve videoId': () => !!(body && body.videoId),
  });
  if (ok) uploadsAccepted.add(1);
  else {
    uploadsRejected.add(1);
    console.error(`upload VU ${vu} recusado: ${res.status} ${res.body}`);
  }
}

function listAll(token) {
  const res = http.get(`${BASE_URL}/videos?size=${Math.max(UPLOADS * 2, 100)}`,
    { headers: { Authorization: `Bearer ${token}` }, tags: { name: 'list' } });
  if (res.status !== 200) fail(`listagem falhou: ${res.status} ${res.body}`);
  return json(res).content;
}

export function teardown(data) {
  // O usuario e novo, entao tudo que ele tem veio deste teste.
  let videos = listAll(data.token);
  const persisted = videos.length;
  const lost = Math.max(0, UPLOADS - persisted);
  requestsLost.add(lost);
  check(null, { [`${UPLOADS} enviados = ${persisted} persistidos`]: () => lost === 0 });

  const byStatus = (list) => list.reduce((acc, v) => ((acc[v.status] = (acc[v.status] || 0) + 1), acc), {});
  console.log(`persistidos: ${persisted}/${UPLOADS} | status: ${JSON.stringify(byStatus(videos))}`);

  if (!WAIT_FOR_PROCESSING) {
    console.log('WAIT_FOR_PROCESSING=false: nao espera o worker (rode com true quando o video-processor existir).');
    return;
  }

  const deadline = Date.now() + PROCESSING_TIMEOUT_S * 1000;
  let pending = videos.filter((v) => v.status !== 'COMPLETED' && v.status !== 'FAILED');
  while (pending.length > 0 && Date.now() < deadline) {
    sleep(5);
    videos = listAll(data.token);
    pending = videos.filter((v) => v.status !== 'COMPLETED' && v.status !== 'FAILED');
    console.log(`aguardando worker: ${JSON.stringify(byStatus(videos))}`);
  }
  const completed = videos.filter((v) => v.status === 'COMPLETED').length;
  videosNotCompleted.add(UPLOADS - completed);
  check(null, { [`${UPLOADS} enviados = ${completed} processados`]: () => completed === UPLOADS });
}

export function handleSummary(data) {
  // setup_data traz o JWT do setup(): nunca vai para o relatorio versionado.
  delete data.setup_data;
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const text = textSummary(data, { indent: ' ', enableColors: false });
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    [`docs/load/${stamp}-summary.json`]: JSON.stringify(data, null, 2),
    [`docs/load/${stamp}-summary.txt`]: text,
  };
}
