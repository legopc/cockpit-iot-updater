import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_url_fetch_status_renders_preview_without_selected_file():
    script = r'''
const fs = require('fs');
const vm = require('vm');

const elements = {};
function element(id) {
  if (!elements[id]) {
    elements[id] = {
      id,
      textContent: '',
      style: {},
      className: '',
      title: '',
      disabled: null,
      classList: { remove() {}, add() {} },
      addEventListener() {},
      appendChild() {},
      remove() {},
    };
  }
  return elements[id];
}

function resolved(value) {
  return {
    then(fn) { return resolved(fn(value)); },
    catch() { return this; },
    always(fn) { fn(); return this; },
  };
}

const status = {
  stage: 'idle',
  progress_pct: 100,
  message: 'Bundle ready: vv99. Review and confirm to apply.',
  version_info: { version: 'v99', bundle_size_bytes: 2097152, dry_run: false },
};

const context = {
  console,
  TextDecoder,
  Date,
  JSON,
  Math,
  setTimeout() { return 0; },
  clearTimeout() {},
  setInterval() { return 0; },
  clearInterval() {},
  location: { reload() {} },
  window: { addEventListener() {} },
  document: {
    addEventListener() {},
    createElement() { return element('created'); },
    querySelector() { return null; },
    getElementById: element,
  },
  cockpit: {
    http() {
      return {
        get(path) {
          if (path === '/status') return resolved(JSON.stringify(status));
          if (path === '/version-preview') return resolved(JSON.stringify(status.version_info));
          if (path === '/bootc-status') return resolved(JSON.stringify({ booted: { version: 'v98' } }));
          return resolved('{}');
        },
        request() { return resolved('{}'); },
      };
    },
    resolve() { return resolved(); },
  },
};

vm.createContext(context);
vm.runInContext(fs.readFileSync('cockpit-page/update.js', 'utf8'), context);
context.state.selectedFile = null;
context.state.versionPreview = null;
context.pollStatus();

if (!context.state.versionPreview || context.state.versionPreview.version !== 'v99') {
  throw new Error('versionPreview was not populated from status version_info');
}
if (element('btn-apply').disabled !== false) {
  throw new Error('apply button was not enabled for URL-fetched bundle');
}
if (element('dz-sub').textContent !== '2.0 MB — ready to apply') {
  throw new Error('ready text did not use bundle_size_bytes: ' + element('dz-sub').textContent);
}
'''
    result = subprocess.run(
        ["node", "-e", script],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
