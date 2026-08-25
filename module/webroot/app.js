import { exec } from './kernelsu.js';

const moduleDir = '/data/adb/modules/wireguard-server-ksu';
const output = document.querySelector('#status');

async function run(command) {
  output.textContent = 'Working…';
  try {
    const result = await exec(`${moduleDir}/scripts/server.sh ${command}`);
    const text = result.stdout || `Exit code: ${result.errno}`;
    output.textContent = text;
    server.textContent = text.includes('status=stopped') ? 'Stopped' : 'Running';
  } catch (error) {
    output.textContent = String(error);
  }
}

document.querySelectorAll('[data-cmd]').forEach(button => button.addEventListener('click', () => run(button.dataset.cmd)));
async function loadSummary() {
  try {
    const [config, peerCount] = await Promise.all([exec(`sed -n 's/^ENDPOINT=//p' ${moduleDir}/data/config/server.env`), exec(`wc -l < ${moduleDir}/data/config/peers.txt`)]);
    endpoint.textContent = config.stdout?.trim() || 'Not configured';
    peers.textContent = peerCount.stdout?.trim() || '0';
  } catch (_) { endpoint.textContent = 'Not configured'; peers.textContent = '0'; }
}
loadSummary();
run('status');
