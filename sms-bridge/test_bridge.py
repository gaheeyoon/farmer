import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

spec=importlib.util.spec_from_file_location('bridge',Path(__file__).with_name('bridge.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class BridgeTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.journal=b.Journal(self.root/'journal.sqlite');self.config={'id':str(uuid.uuid4()),'secret':'a'*64};self.job={'id':str(uuid.uuid4()),'phone':'01012345678','body':'테스트 본문'}
 def tearDown(self):self.journal.db.close();self.tmp.cleanup()
 def test_success_exactly_once(self):
  sender=Mock();api=Mock();b.dispatch(self.job,self.config,self.journal,sender,api);b.dispatch(self.job,self.config,self.journal,sender,api);sender.assert_called_once();api.assert_called_once();self.assertTrue(self.journal.get(self.job['id'])['acked'])
 def test_ack_lost_does_not_resend(self):
  sender=Mock();api=Mock(side_effect=OSError('offline'))
  with self.assertRaises(OSError):b.dispatch(self.job,self.config,self.journal,sender,api)
  self.assertEqual(self.journal.get(self.job['id'])['state'],'sent');ok=Mock();b.flush(self.journal,self.config,ok);sender.assert_called_once();self.assertTrue(self.journal.get(self.job['id'])['acked'])
 def test_crash_marks_uncertain(self):
  self.journal.set(self.job['id'],self.config['id'],'sending');sender=Mock();api=Mock();b.dispatch(self.job,self.config,self.journal,sender,api);sender.assert_not_called();self.assertEqual(api.call_args.args[2]['state'],'uncertain')
 def test_timeout_marks_uncertain(self):
  sender=Mock(side_effect=subprocess.TimeoutExpired('osascript',45));api=Mock();b.dispatch(self.job,self.config,self.journal,sender,api);self.assertEqual(api.call_args.args[2]['state'],'uncertain')
 def test_failure(self):
  api=Mock();b.dispatch(self.job,self.config,self.journal,Mock(side_effect=RuntimeError('not permitted')),api);self.assertEqual(api.call_args.args[2]['state'],'failed')
 def test_safe_number_is_not_converted_or_truncated(self):
  with patch.object(b.subprocess,'run',return_value=Mock(returncode=0)) as run:
   b.send_message('050212345678','기존 안내 그대로, 송장 두 개\n둘째 줄')
   self.assertEqual(run.call_args.args[0][-2:],["050212345678",'기존 안내 그대로, 송장 두 개\n둘째 줄'])
 def test_mobile_destination_unchanged(self):
  with patch.object(b.subprocess,'run',return_value=Mock(returncode=0)) as run:
   b.send_message('01012345678','테스트 본문');self.assertEqual(run.call_args.args[0][-2],'+821012345678')
 def test_malformed_safe_number_never_dispatches(self):
  with patch.object(b.subprocess,'run') as run:
   for phone in ['05021234567','0502123456789','050312345678','123','0502-abcd-efgh']:
    with self.assertRaises(ValueError):b.send_message(phone,'본문')
   run.assert_not_called()
 def test_config_private_and_links(self):
  b.write_config(self.config,self.root);self.assertEqual(b.load_config(self.root),self.config);self.assertEqual((self.root/'connection.json').stat().st_mode&0o777,0o600)
  self.assertEqual(b.parse_link('gogumap-sms://pair?device='+self.config['id']+'&secret='+self.config['secret']),self.config)
  self.assertIsNone(b.parse_link('gogumap-sms://start'))
  for link in ['https://evil/pair','gogumap-sms://pair?device=bad&secret=bad','gogumap-sms://start?run=evil','gogumap-sms://pair?device='+self.config['id']+'&secret='+self.config['secret']+'&url=https://evil']:
   with self.assertRaises(ValueError):b.parse_link(link)

if __name__=='__main__':unittest.main()
