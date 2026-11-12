#!/usr/bin/env python3
"""Mac-only consumer for admin-approved SMS snapshots. Never imports admin sessions."""
import argparse
import fcntl
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

BACKEND = 'https://nfznsjltgfddnskernna.supabase.co'
PUBLIC_KEY = 'sb_publishable_FnP_EfsjA5sLjNU3MDIkgA_3bAh6GzY'
ADMIN_URL = 'https://yoongahee.com/farmer/admin'
DATA = Path.home() / 'Library/Application Support/GogumapSMS'
SCRIPT = '''on run argv
 set thePhone to item 1 of argv
 set theText to item 2 of argv
 tell application "Messages"
  set smsService to 1st service whose service type = SMS
  set theBuddy to buddy thePhone of smsService
  send theText to theBuddy
 end tell
end run'''


def dialog(text, confirm=False):
    script = 'on run argv\n display dialog (item 1 of argv) buttons ' + ('{"취소", "연결"} default button "연결"' if confirm else '{"확인"} default button "확인"') + '\nend run'
    result = subprocess.run(['/usr/bin/osascript', '-e', script, text], capture_output=True, text=True)
    return result.returncode == 0


def storage(root=DATA):
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    return root


def load_config(root=DATA):
    data = json.loads((root / 'connection.json').read_text())
    uuid.UUID(data['id'])
    if not re.fullmatch('[a-f0-9]{64}', data['secret']):
        raise ValueError('Invalid connection')
    return data


def write_config(data, root=DATA):
    storage(root)
    tmp = root / 'connection.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, root / 'connection.json')
    (root / 'connection.json').chmod(0o600)


def rpc(config, action, data=None):
    payload = {'p_device': config['id'], 'p_secret': config['secret'], 'p_action': action, 'p_data': data or {}}
    req = Request(BACKEND + '/rest/v1/rpc/farmer_sms_bridge', data=json.dumps(payload).encode(), headers={'apikey': PUBLIC_KEY, 'Content-Type': 'application/json'}, method='POST')
    with urlopen(req, timeout=15) as response:
        return json.load(response)


class Journal:
    """Only job identities and outcomes are cached; message text stays in the DB."""
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute('pragma synchronous=FULL')
        self.db.execute('create table if not exists jobs(id text primary key,device text not null,state text not null,error text not null default \'\',acked integer not null default 0)')
        self.db.commit()
        Path(path).chmod(0o600)

    def get(self, job_id):
        row = self.db.execute('select state,error,acked from jobs where id=?', [job_id]).fetchone()
        return None if row is None else {'state': row[0], 'error': row[1], 'acked': bool(row[2])}

    def set(self, job_id, device, state, error=''):
        self.db.execute('insert into jobs(id,device,state,error) values(?,?,?,?) on conflict(id) do update set state=excluded.state,error=excluded.error', [job_id, device, state, error])
        self.db.commit()

    def acknowledge(self, job_id):
        self.db.execute('update jobs set acked=1 where id=?', [job_id])
        self.db.commit()

    def pending(self, device):
        return self.db.execute('select id,state,error from jobs where device=? and acked=0', [device]).fetchall()

    def has_pending(self):
        return bool(self.db.execute('select 1 from jobs where acked=0 limit 1').fetchone())


def send_message(phone, text):
    if not re.fullmatch(r'01\d{8,9}', phone) or not text or len(text) > 10000:
        raise ValueError('잘못된 문자 요청입니다.')
    result = subprocess.run(['/usr/bin/osascript', '-e', SCRIPT, '+82' + phone[1:], text], capture_output=True, text=True, timeout=45)
    if result.returncode:
        if '-1743' in result.stderr or 'not authorized' in result.stderr.lower():
            raise RuntimeError('Mac 시스템 설정의 개인정보 보호 및 보안 > 자동화에서 메시지 제어를 허용해 주세요.')
        raise RuntimeError('Mac 메시지 앱에 전달하지 못했습니다. 아이폰 문자 메시지 전달 설정을 확인해 주세요.')


def dispatch(job, config, journal, sender=send_message, api=rpc):
    """An uncertain send is never automatically executed again."""
    uuid.UUID(job['id'])
    previous = journal.get(job['id'])
    if previous:
        if previous['state'] == 'sending':
            journal.set(job['id'], config['id'], 'uncertain', '프로그램 종료 전 발송 여부를 확인하지 못했습니다.')
    else:
        journal.set(job['id'], config['id'], 'sending')
        try:
            sender(job['phone'], job['body'])
        except subprocess.TimeoutExpired:
            journal.set(job['id'], config['id'], 'uncertain', '메시지 앱 응답이 지연되어 실제 발송 여부를 확인해 주세요.')
        except Exception as error:
            journal.set(job['id'], config['id'], 'failed', str(error)[:500])
        else:
            journal.set(job['id'], config['id'], 'sent')
    result = journal.get(job['id'])
    if not result['acked']:
        api(config, 'ack', {'id': job['id'], 'state': result['state'], 'error': result['error']})
        journal.acknowledge(job['id'])


def flush(journal, config, api=rpc):
    for job_id, state, error in journal.pending(config['id']):
        if state == 'sending':
            state, error = 'uncertain', '프로그램 종료 전 발송 여부를 확인하지 못했습니다.'
            journal.set(job_id, config['id'], state, error)
        api(config, 'ack', {'id': job_id, 'state': state, 'error': error})
        journal.acknowledge(job_id)


def worker(root=DATA):
    storage(root)
    with (root / 'worker.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        journal = Journal(root / 'outcomes.sqlite')
        running = [True]
        signal.signal(signal.SIGTERM, lambda *_: running.__setitem__(0, False))
        next_send = 0
        while running[0]:
            try:
                config = load_config(root)
                flush(journal, config)
                rpc(config, 'poll')
                if time.monotonic() >= next_send:
                    job = rpc(config, 'claim').get('job')
                    if job:
                        dispatch(job, config, journal)
                        next_send = time.monotonic() + 20
            except Exception:
                # No message bodies, phone numbers or credentials are printed to logs.
                pass
            for _ in range(5):
                if not running[0]:
                    break
                time.sleep(1)


def parse_link(value):
    link = urlparse(value)
    if link.scheme != 'gogumap-sms' or link.path not in ('', '/') or link.fragment:
        raise ValueError('Invalid launch link')
    if link.netloc == 'start' and not link.query:
        return None
    if link.netloc != 'pair':
        raise ValueError('Invalid launch action')
    params = parse_qs(link.query, strict_parsing=True)
    if set(params) != {'device', 'secret'} or any(len(v) != 1 for v in params.values()):
        raise ValueError('Invalid pairing link')
    device, secret = params['device'][0], params['secret'][0]
    uuid.UUID(device)
    if not re.fullmatch('[a-f0-9]{64}', secret):
        raise ValueError('Invalid pairing secret')
    return {'id': device, 'secret': secret}


def launch(url=None, root=DATA):
    storage(root)
    if url:
        try:
            connection = parse_link(url)
        except ValueError:
            dialog('올바른 실행 링크가 아닙니다. 관리자 화면에서 다시 연결해 주세요.')
            return
        if connection:
            journal = Journal(root / 'outcomes.sqlite')
            if journal.has_pending():
                if not dialog('이전 연결에서 결과를 저장하지 못한 문자가 있습니다. 관리자 발송 기록과 Mac 메시지 앱에서 확인해 주세요. 새 Mac 연결을 진행할까요?', confirm=True):
                    return
            if not dialog('고구맙습니다 관리자 페이지에 이 Mac을 연결할까요? 관리자에서 발송을 요청한 문자만 메시지 앱에 전달합니다.', confirm=True):
                return
            try:
                rpc(connection, 'poll')
            except Exception:
                dialog('Mac 연결을 확인하지 못했습니다. 관리자 화면에서 새 연결을 만든 뒤 다시 시도해 주세요.')
                return
            write_config(connection, root)
    try:
        load_config(root)
    except (OSError, ValueError, KeyError):
        dialog('관리자 페이지의 문자 발송 메뉴에서 ‘이 Mac 연결하기’를 누른 뒤 ‘이 Mac 연결 마치기’를 눌러 주세요.')
        subprocess.run(['/usr/bin/open', ADMIN_URL], check=False)
        return
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--worker'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--url')
    args = parser.parse_args()
    if args.worker:
        worker()
    else:
        launch(args.url)


if __name__ == '__main__':
    main()
