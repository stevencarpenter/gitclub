#!/usr/bin/env python3
"""Explicit missing refs must not be confused with an empty default branch."""
import json
import secrets
import sys
import urllib.error
import urllib.request

base = sys.argv[1].rstrip('/')
token = ''

def call(method, path, body=None, expected=200):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    result = json.load(response)
    assert response.status == expected, (path, response.status, result)
    return result

name = 'refs' + secrets.token_hex(5)
session = call('POST', '/api/auth/register', {'username': name, 'password': secrets.token_hex(16)}, 201)
token = session['token']
repo = call('POST', '/api/repos', {'owner': name, 'name': 'empty'}, 201)['repository']
path = '/api/repos/' + str(repo['id'])
assert call('GET', path + '/tree')['entries'] == []
assert call('GET', path + '/commits')['commits'] == []
call('GET', path + '/tree?ref=missing', expected=404)
call('GET', path + '/commits?ref=missing', expected=404)
call('GET', path + '/tree?ref=-invalid', expected=404)
call('POST', '/api/auth/logout', {})
print('PASS explicit ref lookup and empty default branch')
