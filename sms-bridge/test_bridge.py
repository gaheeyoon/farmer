import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock
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
 def test_config_private_and_links(self):
  b.write_config(self.config,self.root);self.assertEqual(b.load_config(self.root),self.config);self.assertEqual((self.root/'connection.json').stat().st_mode&0o777,0o600)
  self.assertEqual(b.parse_link('gogumap-sms://pair?device='+self.config['id']+'&secret='+self.config['secret']),self.config)
  self.assertIsNone(b.parse_link('gogumap-sms://start'))
  for link in ['https://evil/pair','gogumap-sms://pair?device=bad&secret=bad','gogumap-sms://start?run=evil','gogumap-sms://pair?device='+self.config['id']+'&secret='+self.config['secret']+'&url=https://evil']:
   with self.assertRaises(ValueError):b.parse_link(link)

if __name__=='__main__':unittest.main()
