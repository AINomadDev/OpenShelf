"""Upload generated sample.mov, then measure uncached frame reads on each provider.
Only accesses a new benchmark folder; retains samples and reports for inspection.
Requires ffmpeg and an authorized OpenShelf rclone configuration.
"""
import base64, hashlib, json, os, pathlib, platform, secrets, subprocess, time, urllib.request, uuid

workspace = pathlib.Path(__file__).resolve().parent.parent
root = workspace / '.build/stream-check'
engine = pathlib.Path.home() / 'Applications/OpenShelf.app/Contents/Resources/rclone'
ffmpeg = '/opt/homebrew/bin/ffmpeg'
sample = root / 'sample.mov'
folder = 'OpenShelf streaming check ' + uuid.uuid4().hex[:8]
size = sample.stat().st_size
reports = []

def frame(path, second):
    start = time.monotonic()
    result = subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-ss', str(second), '-i', str(path), '-frames:v', '1', '-f', 'framemd5', '-'], capture_output=True, timeout=60, check=True)
    digest = [line for line in result.stdout.decode().splitlines() if not line.startswith('#')][-1].split(',')[-1].strip()
    return digest, round(time.monotonic() - start, 3)

def allocated(cache):
    return sum(p.stat().st_blocks * 512 for p in cache.rglob('*') if p.is_file())

expected = {second: frame(sample, second)[0] for second in (0, 20)}
for index, provider in enumerate(['google', 'icloud']):
    remote = 'openshelf-' + provider + ':' + folder
    subprocess.run([str(engine), 'copyto', str(sample), remote + '/sample.mov', '--retries', '1', '--low-level-retries', '2', '--timeout', '30s'], check=True, timeout=300)
    trial = root / provider / folder
    mount = trial / 'drive'
    cache = trial / 'cache'
    mount.mkdir(parents=True)
    cache.mkdir()
    port = 55841 + index
    password = secrets.token_urlsafe(32)
    env = dict(os.environ, RCLONE_RC_USER='stream-check', RCLONE_RC_PASS=password)
    args = [str(engine), 'nfsmount', remote, str(mount), '--addr', '127.0.0.1:0', '--option', 'nolocks', '--option', 'noappledouble', '--cache-dir', str(cache), '--vfs-cache-mode', 'full', '--vfs-cache-max-size', '5G', '--vfs-cache-min-free-space', '10G', '--vfs-cache-poll-interval', '10s', '--vfs-read-chunk-size', '8M', '--vfs-read-chunk-size-limit', '64M', '--buffer-size', '8M', '--rc', '--rc-addr', f'127.0.0.1:{port}', '--log-file', str(trial/'mount.log')]
    process = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def rpc(endpoint):
        req = urllib.request.Request(f'http://127.0.0.1:{port}/{endpoint}', data=b'')
        req.add_header('Authorization', 'Basic ' + base64.b64encode(('stream-check:'+password).encode()).decode())
        with urllib.request.urlopen(req, timeout=5) as response: return json.load(response)
    mounted = False
    try:
        for _ in range(120):
            mounted = ' on '+str(mount)+' (' in subprocess.check_output(['/sbin/mount']).decode()
            if mounted: break
            if process.poll() is not None: raise RuntimeError('Mount failed: '+str(trial/'mount.log'))
            time.sleep(.25)
        assert mounted, 'Mount timeout'
        reads = []
        for second in (0, 20):
            digest, elapsed = frame(mount/'sample.mov', second)
            assert digest == expected[second], 'Decoded frame mismatch'
            reads.append({'seek_seconds':second, 'decode_seconds':elapsed, 'allocated_cache_bytes':allocated(cache), 'downloaded_bytes':rpc('core/stats')['bytes']})
        cached_digest, cached_time = frame(mount/'sample.mov', 20)
        assert cached_digest == expected[20]
        report = {'provider':provider, 'remote_folder':folder, 'source_bytes':size, 'reads':reads, 'warm_seek_decode_seconds':cached_time, 'allocated_cache_bytes':allocated(cache), 'downloaded_bytes':rpc('core/stats')['bytes']}
        report['partial_download_confirmed'] = 0 < report['downloaded_bytes'] < size and report['allocated_cache_bytes'] < size
        reports.append(report)
        (root/'results.json').write_text(json.dumps(reports, indent=2))
        print(json.dumps(report), flush=True)
        assert report['partial_download_confirmed'], 'Full file was read; do not claim partial access'
    finally:
        if mounted:
            subprocess.run(['/sbin/umount', str(mount)], check=True)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
print('PASS: decoded frame matches, partial downloads, sparse cache allocation, and normal unmount on both providers')
