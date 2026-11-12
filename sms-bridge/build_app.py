#!/usr/bin/env python3
"""Build the URL handler without starting it or accessing Messages."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

src=Path(__file__).resolve().parent
repo=src.parent
output=repo/'downloads'
output.mkdir(exist_ok=True)
stage=repo/'work'/'sms-app-package'
if stage.exists():shutil.rmtree(stage)
stage.mkdir(parents=True)
app=stage/'고구맙습니다 문자발송.app'
subprocess.run(['/usr/bin/osacompile','-o',str(app),str(src/'launcher.applescript')],check=True)
shutil.copy2(src/'bridge.py',app/'Contents/Resources/bridge.py')
p=app/'Contents/Info.plist'
data=plistlib.loads(p.read_bytes());data.update({'CFBundleIdentifier':'com.gogumap.sms','CFBundleName':'고구맙습니다 문자발송','CFBundleShortVersionString':'1.0.0','NSAppleEventsUsageDescription':'관리자에서 요청한 배송 안내를 Mac 메시지 앱에 전달합니다.','CFBundleURLTypes':[{'CFBundleURLName':'고구맙습니다 문자발송','CFBundleURLSchemes':['gogumap-sms']}],'LSUIElement':True});p.write_bytes(plistlib.dumps(data))
subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
installer=stage/'처음 설치.command'
installer.write_text('''#!/bin/bash
set -eu
source_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$source_dir/고구맙습니다 문자발송.app" "$HOME/Applications/고구맙습니다 문자발송.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/고구맙습니다 문자발송.app"
/usr/bin/open https://yoongahee.com/farmer/admin
printf '\\n설치했습니다. 관리자 문자 발송에서 이 Mac을 연결해 주세요.\\n'
''');installer.chmod(0o755)
(stage/'사용법.txt').write_text('''[처음 한 번]
1. 처음 설치.command를 실행합니다. 확인창이 나오면 Mac에서 실행을 허용해 주세요.
2. 관리자 페이지 > 문자 발송 > 처음 연결하거나 Mac 변경하기 > 이 Mac 연결하기를 누릅니다.
3. 이 Mac 연결 마치기를 누르고, Mac의 연결 확인창에서 연결을 누릅니다.
4. 아이폰의 문자 메시지 전달에서 이 Mac을 켜 두세요.

[배송 안내]
1. 발송 프로그램 실행하기를 누릅니다.
2. 주문 · 재고 > 배송 중 > 주문 체크 > 선택 주문 문자 보내기.
3. 중량별 실제 문자 내용과 송장을 확인하고 테스트 후 발송합니다.
4. 첫 발송 때 Mac의 메시지 제어 허용이 필요할 수 있습니다.

이 앱을 실행하는 것만으로 새 문자가 발송되지는 않습니다. 관리자에서 명시적으로 등록한 대기 작업만 처리합니다.
20초 간격으로 메시지 앱에 전달하며 실제 도착 여부는 확인할 수 없습니다.
발송 결과가 불확실한 기록은 메시지 앱을 확인한 뒤 관리자에서 다시 준비해 주세요.
이전 문자 프로그램의 파일과 sent_log.csv는 그대로 보관하세요.
''')
archive=output/'gogumap-sms-mac.zip'
subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(stage),str(archive)],check=True)
print(app)
print(archive)
