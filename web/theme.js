// Load before the stylesheet so a saved light preference applies before paint.
function setGitClubTheme(value, remember = false) {
  const theme = value === 'light' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  document.querySelector('meta[name="color-scheme"]').content = theme;
  document.querySelector('meta[name="theme-color"]').content = theme === 'dark' ? '#151c18' : '#fbfcfa';
  if (remember) {
    try { localStorage.setItem('gitclub:theme', theme); } catch { /* The theme still works when storage is disabled. */ }
  }
}

try { setGitClubTheme(localStorage.getItem('gitclub:theme')); }
catch { setGitClubTheme('dark'); }
