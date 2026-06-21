const { execSync } = require('child_process');
try {
  const out = execSync('go build ./... 2>&1', { cwd: 'C:/mySpace/CorssLink/poc' });
  console.log(out.toString());
  console.log('BUILD OK');
} catch(e) {
  console.log(e.stdout?.toString() || '');
  console.log(e.stderr?.toString() || '');
  console.log('BUILD FAILED');
}
