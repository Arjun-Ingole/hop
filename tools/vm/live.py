"""Temporary, while the probe is being written: a way to look at and steer a running VM through a branch.

Screens and output are pushed to the branch given in HOPVM_LIVE_BRANCH. Python put in cmd.py on that
branch is run in the VM's process. It only exists when that variable is set."""
import base64
import contextlib
import io
import json
import os
import threading
import time
import traceback
import urllib.error
import urllib.request


class Live:
    @staticmethod
    def from_environment():
        branch, token = os.environ.get('HOPVM_LIVE_BRANCH'), os.environ.get('GITHUB_TOKEN')
        return Live(branch, token, os.environ['GITHUB_REPOSITORY']) if branch and token else None

    def __init__(self, branch, token, repo):
        self.branch, self.token, self.repo = branch, token, repo
        self.lock = threading.Lock()
        self.seen = None

    def api(self, method, path, body=None):
        url = f'https://api.github.com/repos/{self.repo}/{path}'
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=60) as reply:
            return json.load(reply)

    def push(self, name, data):
        body = {'message': name, 'branch': self.branch, 'content': base64.b64encode(data).decode()}
        with self.lock:
            for attempt in range(4):
                try:
                    try:
                        body['sha'] = self.api('GET', f'contents/out/{name}?ref={self.branch}')['sha']
                    except urllib.error.HTTPError:
                        body.pop('sha', None)
                    self.api('PUT', f'contents/out/{name}', body)
                    return
                except Exception as ex:
                    print(f'live: push {name}: {ex}', flush=True)
                    time.sleep(3 + attempt * 5)

    def push_file(self, path):
        with open(path, 'rb') as f:
            threading.Thread(target=self.push, args=(os.path.basename(path), f.read()), daemon=True).start()

    def serve(self, scope):
        """Runs each new cmd.py in a thread of its own, so a long one doesn't stop the next."""
        count = 0
        self.push('ready.txt', time.strftime('%H:%M:%S').encode())
        while True:
            time.sleep(8)
            try:
                found = self.api('GET', f'contents/cmd.py?ref={self.branch}')
            except Exception as ex:
                print(f'live: {ex}', flush=True)
                continue
            if found['sha'] == self.seen:
                continue
            first = self.seen is None
            self.seen = found['sha']
            if first:
                continue    # an old command, from before this VM
            count += 1
            source = base64.b64decode(found['content']).decode()
            threading.Thread(target=self.run, args=(source, scope, count), daemon=True).start()

    def run(self, source, scope, count):
        tag = f'cmd-{time.strftime("%H%M%S")}.txt'
        buffer = io.StringIO()

        class Tee:
            def write(_, text):
                buffer.write(text)
                import sys
                sys.__stdout__.write(text)

            def flush(_):
                pass

        done = threading.Event()

        def flusher():
            while not done.wait(45):
                self.push(tag, buffer.getvalue().encode())

        threading.Thread(target=flusher, daemon=True).start()
        with contextlib.redirect_stdout(Tee()):
            try:
                exec(compile(source, 'cmd.py', 'exec'), scope)
            except BaseException:
                print(traceback.format_exc())
        done.set()
        self.push(tag, (buffer.getvalue() + '\n[finished]').encode())
