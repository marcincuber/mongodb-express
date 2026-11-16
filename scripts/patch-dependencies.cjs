const fs = require('node:fs');

const packageFile = process.argv[2] || 'package.json';
const pkg = JSON.parse(fs.readFileSync(packageFile, 'utf8'));
const oidcPackage = 'express-openid-connect';
const oidcVersion = pkg.dependencies?.[oidcPackage] ?? pkg.devDependencies?.[oidcPackage];

if (!oidcVersion) {
  throw new Error('Upstream no longer declares express-openid-connect; review OIDC support before building.');
}

// Retain the upstream OIDC dependency when Yarn prunes development packages.
pkg.dependencies ??= {};
pkg.dependencies[oidcPackage] = oidcVersion;
if (pkg.devDependencies) delete pkg.devDependencies[oidcPackage];

// CVE-2026-111181: update the application's body-parser within its existing 2.x major.
pkg.dependencies['body-parser'] = '2.4.0';

pkg.resolutions = {
  ...pkg.resolutions,
  // CVE-2026-19481 and CVE-2026-19484: patch the multipart parser.
  '@fastify/busboy': '3.2.1',
  // CVE-2026-111181: Express 4 needs the patched 1.x body-parser, independently of the app's 2.x copy.
  'express/body-parser': '1.20.9',
  // CVE-2026-118772: retain Joi 17 with its security fix.
  joi: '17.13.9',
  // CVE-2026-4800: patch Lodash without changing its major version.
  lodash: '4.18.0',
  // CVE-2026-4867: patch Express 4's route matching dependency within its 0.1.x line.
  'path-to-regexp': '0.1.13',
  // CVE-2026-90711 (CRITICAL): patch Express's proxy address dependency.
  'proxy-addr': '2.0.8',
};

fs.writeFileSync(packageFile, JSON.stringify(pkg, null, 2) + '\n');
