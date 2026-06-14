const state = {
  nodes: []
};

const $ = (selector) => document.querySelector(selector);

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: {'Content-Type': 'application/json', ...(options.headers || {})},
    ...options
  });
  if (res.status === 401) {
    location.href = '/login.html';
    return null;
  }
  if (!res.ok) {
    const data = await res.json().catch(() => ({detail: res.statusText}));
    throw new Error(data.detail || '请求失败');
  }
  return res.json();
}

function fmt(value) {
  if (!value) return '永不过期';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  })[char]);
}

function renderNodes() {
  const body = $('#nodesBody');
  body.innerHTML = '';
  for (const node of state.nodes) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><strong>${escapeHtml(node.name)}</strong></td>
      <td>${escapeHtml(node.protocol)}</td>
      <td><span class="badge ${node.enabled ? 'ok' : 'off'}">${node.enabled ? '启用' : '停用'}</span></td>
      <td>${escapeHtml(fmt(node.expire_at))}</td>
      <td class="config-cell" title="${escapeHtml(node.config_file)}">${escapeHtml(node.config_file)}</td>
      <td class="actions">
        <button data-action="url" data-name="${escapeHtml(node.name)}">URL</button>
        <button data-action="qr" data-name="${escapeHtml(node.name)}">QR</button>
        <button data-action="info" data-name="${escapeHtml(node.name)}">Info</button>
        <button data-action="expire" data-name="${escapeHtml(node.name)}">到期</button>
        <button data-action="delete" data-name="${escapeHtml(node.name)}" class="danger">删除</button>
      </td>
    `;
    body.appendChild(tr);
  }
  $('#totalNodes').textContent = String(state.nodes.length);
  $('#enabledNodes').textContent = String(state.nodes.filter((node) => node.enabled).length);
}

async function loadMe() {
  const data = await api('/api/me');
  if (data) $('#userLine').textContent = data.username;
}

async function loadNodes() {
  const data = await api('/api/nodes');
  if (!data) return;
  state.nodes = data.nodes || [];
  renderNodes();
}

async function loadStatus() {
  const data = await api('/api/status');
  if (!data) return;
  $('#serviceState').textContent = data.active || 'unknown';
  $('#statusBox').textContent = data.status || `${data.service}: ${data.active}`;
}

async function loadLogs() {
  const data = await api('/api/logs');
  if (!data) return;
  $('#systemLogsBox').textContent = data.system_logs || '';
  const box = $('#auditBox');
  box.innerHTML = '';
  for (const log of data.audit_logs || []) {
    const row = document.createElement('div');
    row.className = 'log-row';
    row.innerHTML = `
      <span>${escapeHtml(fmt(log.created_at))}</span>
      <strong>${escapeHtml(log.action)}</strong>
      <em>${escapeHtml(log.target)}</em>
      <p>${escapeHtml(log.detail)}</p>
    `;
    box.appendChild(row);
  }
}

async function createNode(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const msg = $('#formMessage');
  msg.textContent = '正在调用 sing-box 添加节点...';
  const payload = {
    protocol: form.protocol.value,
    expire_at: form.expire_at.value || null
  };
  try {
    const data = await api('/api/nodes', {
      method: 'POST',
      body: JSON.stringify(payload)
    });
    form.reset();
    msg.textContent = `节点已添加：${data.node}`;
    await Promise.all([loadNodes(), loadStatus(), loadLogs()]);
  } catch (error) {
    msg.textContent = error.message;
  }
}

function openDialog(title, text, preText = '') {
  $('#dialogTitle').textContent = title;
  $('#urlText').value = text || '';
  $('#dialogPre').textContent = preText || '';
  $('#nodeDialog').showModal();
}

async function handleNodeAction(event) {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  const name = button.dataset.name;
  const action = button.dataset.action;
  if (action === 'delete') {
    if (!confirm(`删除节点 ${name}？`)) return;
    await api(`/api/nodes/${encodeURIComponent(name)}`, {method: 'DELETE'});
    await Promise.all([loadNodes(), loadLogs()]);
  }
  if (action === 'expire') {
    const next = prompt('输入新的到期日期，例如 2026-12-31。留空表示永不过期。');
    if (next === null) return;
    await api(`/api/nodes/${encodeURIComponent(name)}/expire`, {
      method: 'PATCH',
      body: JSON.stringify({expire_at: next.trim() || null})
    });
    await Promise.all([loadNodes(), loadLogs()]);
  }
  if (action === 'url') {
    const data = await api(`/api/nodes/${encodeURIComponent(name)}/url`);
    openDialog(`${name} URL`, data.url || '');
  }
  if (action === 'qr') {
    const data = await api(`/api/nodes/${encodeURIComponent(name)}/qr`);
    openDialog(`${name} QR`, '', data.qr || '');
  }
  if (action === 'info') {
    const data = await api(`/api/nodes/${encodeURIComponent(name)}/info`);
    openDialog(`${name} Info`, '', data.info || '');
  }
}

async function restartService() {
  if (!confirm('重启 sing-box？')) return;
  const data = await api('/api/restart', {method: 'POST'});
  $('#statusBox').textContent = data.output || 'restart ok';
  await Promise.all([loadStatus(), loadLogs()]);
}

async function logout() {
  await api('/api/logout', {method: 'POST'});
  location.href = '/login.html';
}

async function init() {
  $('#nodeForm').addEventListener('submit', createNode);
  $('#nodesBody').addEventListener('click', handleNodeAction);
  $('#refreshBtn').addEventListener('click', loadNodes);
  $('#statusBtn').addEventListener('click', loadStatus);
  $('#logsBtn').addEventListener('click', loadLogs);
  $('#restartBtn').addEventListener('click', restartService);
  $('#logoutBtn').addEventListener('click', logout);
  $('#closeDialog').addEventListener('click', () => $('#nodeDialog').close());
  await loadMe();
  await Promise.all([loadNodes(), loadStatus(), loadLogs()]);
}

init().catch((error) => {
  console.error(error);
});
