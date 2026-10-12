# -*- coding: utf-8 -*-
"""随身WiFi 短信网页服务器（Python 版，可选）

功能与零依赖的 sms_web_server.ps1 完全一致。两者按 config.json 的
server_engine 选择其一运行；默认使用 PowerShell 版（Windows 自带，无需装 Python）。

接口：
  POST /send            {"id","to","body"}   追加发送队列
  POST /delete          {"index"}            追加删除队列（轮询脚本用 AT+CMGD 删除）
  POST /mark_read       {"index"}            标记单条已读
  POST /mark_read_all   {"indexes":[...]}    批量标记已读
  POST /contacts        {"from","name"}      保存联系人备注
  GET  /contacts                             读取联系人备注
  GET  /send_result                          发送结果 {id: {status,message,ts}}
  GET  /events                               SSE 实时推送短信列表
  其余路径按静态文件返回（含 data.json）
"""
import functools
import json
import os
import threading
import time
import uuid
from http.server import SimpleHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

try:
    from http.server import ThreadingHTTPServer as _HTTPServer
except ImportError:  # Python < 3.7
    from http.server import HTTPServer as _HTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(BASE)
CONFIG = os.path.join(ROOT_DIR, 'config.json')
DATA = os.path.join(BASE, 'data.json')
QUEUE = os.path.join(BASE, 'send_queue.json')
DELETE_Q = os.path.join(BASE, 'delete_queue.json')
MARKS = os.path.join(BASE, 'read_marks.json')
CONTACTS = os.path.join(BASE, 'contacts.json')
RESULT = os.path.join(BASE, 'send_result.json')

_lock = threading.Lock()


def load_config():
    cfg = {'web_host': '127.0.0.1', 'web_port': 8666, 'access_token': ''}
    try:
        with open(CONFIG, encoding='utf-8') as f:
            data = json.load(f)
        for key in cfg:
            if data.get(key) is not None:
                cfg[key] = data[key]
        cfg['web_port'] = int(cfg['web_port'])
    except Exception:
        pass
    return cfg


CFG = load_config()
TOKEN = str(CFG.get('access_token') or '')


def read_json(path, default):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def append_item(path, item):
    with _lock:
        data = read_json(path, [])
        if not isinstance(data, list):
            data = []
        data.append(item)
        write_json(path, data)


def now_ms():
    return int(time.time() * 1000)


class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    # ---------- 工具 ----------
    def _send(self, body, ctype, code=200):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(json.dumps(obj, ensure_ascii=False).encode('utf-8'),
                   'application/json; charset=utf-8', code)

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0) or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode('utf-8'))
        except Exception:
            return {}

    def _authorized(self):
        if not TOKEN:
            return True
        path = urlparse(self.path).path
        if path in ('/', '/index.html'):
            return True
        if self.headers.get('X-Auth-Token') == TOKEN:
            return True
        q = parse_qs(urlparse(self.path).query)
        return (q.get('token') or [''])[0] == TOKEN

    def _chunk(self, data):
        self.wfile.write(b'%x\r\n' % len(data) + data + b'\r\n')
        self.wfile.flush()

    # ---------- 路由 ----------
    def do_GET(self):
        path = urlparse(self.path).path
        if not self._authorized():
            self._json({'ok': False, 'error': 'unauthorized'}, 401)
            return
        if path == '/events':
            self._sse()
        elif path == '/contacts':
            self._json(read_json(CONTACTS, {}))
        elif path == '/send_result':
            self._json(read_json(RESULT, {}))
        else:
            super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._authorized():
            self._json({'ok': False, 'error': 'unauthorized'}, 401)
            return
        try:
            if path == '/send':
                data = self._read_body()
                if not data.get('id') or not data.get('to'):
                    self._json({'ok': False, 'error': '参数不完整'}, 400)
                    return
                append_item(QUEUE, data)
                self._json({'ok': True})

            elif path == '/delete':
                data = self._read_body()
                if data.get('index') is None:
                    self._json({'ok': False, 'error': '参数不完整'}, 400)
                    return
                append_item(DELETE_Q, {'id': uuid.uuid4().hex, 'index': str(data['index'])})
                self._json({'ok': True})

            elif path == '/mark_read':
                data = self._read_body()
                if data.get('index') is not None:
                    append_item(MARKS, {'index': str(data['index']), 'ts': now_ms()})
                self._json({'ok': True})

            elif path == '/mark_read_all':
                data = self._read_body()
                ts = now_ms()
                for i in (data.get('indexes') or []):
                    if i is not None:
                        append_item(MARKS, {'index': str(i), 'ts': ts})
                self._json({'ok': True})

            elif path == '/contacts':
                data = self._read_body()
                frm = str(data.get('from', ''))
                name = str(data.get('name', ''))
                with _lock:
                    m = read_json(CONTACTS, {})
                    if not isinstance(m, dict):
                        m = {}
                    if name.strip():
                        m[frm] = name
                    else:
                        m.pop(frm, None)
                    write_json(CONTACTS, m)
                self._json({'ok': True})

            else:
                self._send(b'', 'text/plain', 404)
        except Exception as e:
            self._json({'ok': False, 'error': str(e)}, 500)

    def _sse(self):
        """SSE：data.json 变化时推送给浏览器（用分块传输保持长连接）"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        try:
            self._chunk(b': connected\n\n')   # 先发注释帧，让浏览器立刻触发 onopen
        except Exception:
            return
        last = None
        try:
            while True:
                try:
                    with open(DATA, encoding='utf-8') as f:
                        text = f.read()
                except Exception:
                    text = ''
                if text and text != last:
                    last = text
                    payload = 'data: ' + text.replace('\r', '').replace('\n', '') + '\n\n'
                    self._chunk(payload.encode('utf-8'))
                time.sleep(0.8)
        except Exception:
            pass   # 客户端断开

    def end_headers(self):
        # 轮询/推送读取的数据一律不缓存
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    handler = functools.partial(Handler, directory=BASE)
    server = _HTTPServer((CFG['web_host'], CFG['web_port']), handler)
    print('SMS web server (Python) on http://%s:%d' % (CFG['web_host'], CFG['web_port']))
    server.serve_forever()
