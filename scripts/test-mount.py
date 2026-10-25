import base64,json,os,pathlib,platform,secrets,subprocess,time,urllib.request,urllib.error,tempfile
workspace=pathlib.Path(__file__).resolve().parent.parent
os.chdir(workspace)
root=pathlib.Path(tempfile.mkdtemp(prefix='mount-check-',dir=workspace/'.build'))
for folder in ['source','drive','cache']:(root/folder).mkdir()
(root/'source/read.txt').write_text('OpenShelf read check\n')
arch='amd64' if platform.machine()=='x86_64' else 'arm64'
engine=pathlib.Path(f'.build/downloads/rclone-v1.75.2-osx-{arch}/rclone').resolve()
password=secrets.token_urlsafe(32)
env=dict(os.environ,RCLONE_RC_USER='openshelf',RCLONE_RC_PASS=password)
args=[str(engine),'nfsmount',str(root/'source'),str(root/'drive'),'--addr','127.0.0.1:0','--option','nolocks','--option','noappledouble','--cache-dir',str(root/'cache'),'--vfs-cache-mode','full','--rc','--rc-addr','127.0.0.1:55739','--log-file',str(root/'test.log')]
p=subprocess.Popen(args,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def stats(auth=True):
    req=urllib.request.Request('http://127.0.0.1:55739/vfs/stats',data=b'')
    if auth:req.add_header('Authorization','Basic '+base64.b64encode(('openshelf:'+password).encode()).decode())
    with urllib.request.urlopen(req,timeout=2) as r:return json.load(r)
mounted=False
try:
    for _ in range(40):
        table=subprocess.check_output(['/sbin/mount']).decode()
        mounted=' on '+str(root/'drive')+' (' in table
        if mounted:break
        if p.poll() is not None:raise RuntimeError('test mount failed; see test.log')
        time.sleep(.25)
    assert mounted
    try:stats(False);raise AssertionError('Control endpoint accepted unauthenticated request')
    except urllib.error.HTTPError as e:assert e.code==401
    assert (root/'drive/read.txt').read_text()=='OpenShelf read check\n'
    payload='OpenShelf authenticated write-back check\n'
    (root/'drive/verified.txt').write_text(payload)
    for _ in range(60):
        status=stats()['diskCache']
        if (root/'source/verified.txt').exists() and (root/'source/verified.txt').read_text()==payload and status['uploadsQueued']==0 and status['uploadsInProgress']==0:break
        time.sleep(.25)
    else:raise AssertionError('Write-back did not finish')
    assert status['erroredFiles']==0
    subprocess.run(['/sbin/umount',str(root/'drive')],check=True)
    mounted=False
    p.wait(timeout=10)
    print('PASS: actual mount, file read/write, completed write-back, authenticated transfer stats, unauthorized request rejection, and normal unmount')
finally:
    if mounted:subprocess.run(['/sbin/umount',str(root/'drive')],check=False)
    if p.poll() is None:p.terminate();p.wait(timeout=10)
