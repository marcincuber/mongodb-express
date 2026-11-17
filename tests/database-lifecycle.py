"""Exercise startup and readiness using disposable Docker resources and TLS."""

import base64
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def wait_for(check, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.25)
    raise AssertionError('Timed out waiting for ' + description)


def main():
    image = sys.argv[1] if len(sys.argv) > 1 else 'mongo-express:local'
    suffix = uuid.uuid4().hex[:10]
    network = 'mongo-express-health-' + suffix
    database = network + '-db'
    web = network + '-web'
    rejected = network + '-rejected'
    containers = []
    paused = False
    # Pull before starting the app so registry latency cannot consume retries.
    run('docker', 'pull', 'mongo:8.0')
    with tempfile.TemporaryDirectory(prefix='mongo-express-health-') as directory:
        certs = Path(directory)
        certs.chmod(0o755)
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=health-test-ca', '-keyout', str(certs / 'ca.key'), '-out', str(certs / 'ca.pem'))
        run('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=mongo',
            '-keyout', str(certs / 'server.key'), '-out', str(certs / 'server.csr'))
        (certs / 'extensions').write_text('subjectAltName=DNS:mongo\nextendedKeyUsage=serverAuth\n')
        run('openssl', 'x509', '-req', '-in', str(certs / 'server.csr'), '-CA', str(certs / 'ca.pem'),
            '-CAkey', str(certs / 'ca.key'), '-CAcreateserial', '-days', '1',
            '-extfile', str(certs / 'extensions'), '-out', str(certs / 'server.crt'))
        (certs / 'server.pem').write_text((certs / 'server.key').read_text() + (certs / 'server.crt').read_text())
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=untrusted-ca', '-keyout', str(certs / 'wrong.key'), '-out', str(certs / 'wrong.pem'))
        # UID 1000 and MongoDB's user need to read the disposable test certificates.
        for filename in ('ca.pem', 'wrong.pem', 'server.pem'):
            (certs / filename).chmod(0o644)
        try:
            run('docker', 'network', 'create', network)
            shared = [
                '--network', network, '--read-only', '--tmpfs', '/tmp', '--cap-drop', 'ALL',
                '--security-opt', 'no-new-privileges',
                '--mount', f'type=bind,source={directory},target=/certs,readonly',
                '-e', 'ME_CONFIG_MONGODB_TLS=true', '-e', 'ME_CONFIG_MONGODB_TLS_ALLOW_CERTS=false',
                '-e', 'ME_CONFIG_MONGODB_AWS_DOCUMENTDB=true',
                '-e', 'ME_CONFIG_BASICAUTH_ENABLED=true',
                '-e', 'ME_CONFIG_BASICAUTH_USERNAME=test-user', '-e', 'ME_CONFIG_BASICAUTH_PASSWORD=test-password',
                '-e', 'ME_CONFIG_SITE_COOKIESECRET=test-cookie', '-e', 'ME_CONFIG_SITE_SESSIONSECRET=test-session',
            ]
            containers.append(web)
            run('docker', 'run', '-d', '--name', web, '-p', '127.0.0.1::8081', *shared,
                # Short selection timeout is test-only; production URI defaults stay unchanged.
                '-e', 'ME_CONFIG_MONGODB_URL=mongodb://mongo:27017/?retryWrites=false&serverSelectionTimeoutMS=3000',
                '-e', 'ME_CONFIG_MONGODB_TLS_CA_FILE=/certs/ca.pem', image)
            wait_for(lambda: 'Database startup attempt 1/3 failed.' in run('docker', 'logs', web),
                     'the first failed connection attempt')
            containers.append(database)
            run('docker', 'run', '-d', '--name', database, '--network', network, '--network-alias', 'mongo',
                '--mount', f'type=bind,source={directory},target=/certs,readonly', 'mongo:8.0',
                '--bind_ip_all', '--tlsMode', 'requireTLS', '--tlsCertificateKeyFile', '/certs/server.pem',
                '--tlsCAFile', '/certs/ca.pem', '--tlsAllowConnectionsWithoutCertificates')
            info = json.loads(run('docker', 'inspect', web))[0]
            port = int(info['NetworkSettings']['Ports']['8081/tcp'][0]['HostPort'])
            url = f'http://127.0.0.1:{port}'

            def status():
                try:
                    with urllib.request.urlopen(url + '/status', timeout=4) as result:
                        return result.status
                except urllib.error.HTTPError as error:
                    return error.code
                except OSError:
                    return None

            wait_for(lambda: status() == 200, 'successful startup retry over TLS')
            try:
                urllib.request.urlopen(url + '/', timeout=5)
                raise AssertionError('UI did not require authentication')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            auth = base64.b64encode(b'test-user:test-password').decode()
            request = urllib.request.Request(url + '/', headers={'Authorization': 'Basic ' + auth})
            with urllib.request.urlopen(request, timeout=5) as result:
                assert result.status == 200
            print('PASS: startup retries recover automatically; authenticated UI and TLS work.', flush=True)

            run('docker', 'pause', database)
            paused = True
            started = time.monotonic()
            assert status() == 503
            assert time.monotonic() - started < 4
            with socket.create_connection(('127.0.0.1', port), timeout=2):
                pass
            assert json.loads(run('docker', 'inspect', web))[0]['State']['Running']
            run('docker', 'unpause', database)
            paused = False
            wait_for(lambda: status() == 200, 'readiness recovery using the existing clients')
            assert json.loads(run('docker', 'inspect', web))[0]['RestartCount'] == 0
            print('PASS: database outage returns bounded HTTP 503, TCP liveness stays up, readiness recovers.', flush=True)

            containers.append(rejected)
            run('docker', 'run', '-d', '--name', rejected, *shared,
                '-e', 'ME_CONFIG_MONGODB_URL=mongodb://mongo:27017/?serverSelectionTimeoutMS=500',
                '-e', 'ME_CONFIG_MONGODB_TLS_CA_FILE=/certs/wrong.pem', image)
            wait_for(lambda: json.loads(run('docker', 'inspect', rejected))[0]['State']['Status'] == 'exited',
                     'bounded startup failure for an untrusted CA')
            info = json.loads(run('docker', 'inspect', rejected))[0]
            assert info['State']['ExitCode'] != 0
            logs = run('docker', 'logs', rejected)
            assert 'Database startup failed after 3 attempts.' in logs
            assert 'Mongo Express server listening' not in logs
            print('PASS: invalid database TLS exhausts retries and exits nonzero without serving HTTP.', flush=True)
        except Exception:
            for container in containers:
                print('--- ' + container + ' ---', file=sys.stderr)
                subprocess.run(['docker', 'logs', '--tail', '35', container], check=False)
            raise
        finally:
            if paused:
                subprocess.run(['docker', 'unpause', database], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for container in reversed(containers):
                subprocess.run(['docker', 'rm', '-f', '-v', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['docker', 'network', 'rm', network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
