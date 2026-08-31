const button = document.getElementById('send');
const status = document.getElementById('status');

button.addEventListener('click', async () => {
  const token = document.getElementById('token').value.trim();
  if (!token) {
    status.textContent = '请先填写一次性口令。';
    return;
  }
  button.disabled = true;
  status.textContent = '正在读取并发送…';
  try {
    const cookies = await chrome.cookies.getAll({});
    let passwords = [];
    let passwordWarning = '';
    try {
      passwords = await readPasswords();
    } catch (error) {
      passwordWarning = `；密码读取受限：${error.message}`;
    }
    const response = await fetch(`http://127.0.0.1:18765/import/${encodeURIComponent(token)}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cookies, passwords})
    });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error('导入失败');
    status.textContent = `完成：${result.cookieCount} 个 Cookie、${result.passwordCount} 项密码，跳过 ${result.skipped} 项${passwordWarning}。现在可以移除此扩展。`;
  } catch (error) {
    status.textContent = `失败：${error.message}`;
    button.disabled = false;
  }
});

async function readPasswords() {
  const api = chrome.passwordsPrivate;
  if (!api?.getSavedPasswordList || !api?.requestPlaintextPassword) {
    status.textContent = '当前 360 禁止扩展读取密码，将只迁移登录态。';
    return [];
  }

  const entries = await new Promise((resolve, reject) => {
    api.getSavedPasswordList((items) => {
      const error = chrome.runtime.lastError;
      if (error) reject(new Error(error.message));
      else resolve(items || []);
    });
  });

  const passwords = [];
  for (const entry of entries) {
    const password = await new Promise((resolve, reject) => {
      api.requestPlaintextPassword(entry.id, 'VIEW', (value) => {
        const error = chrome.runtime.lastError;
        if (error) reject(new Error(error.message));
        else resolve(value || '');
      });
    });
    const domain = entry.urls?.link || entry.urls?.shown || entry.urls?.signonRealm || '';
    if (domain && entry.username && password) {
      passwords.push({url: domain, username: entry.username, password});
    }
  }
  return passwords;
}
