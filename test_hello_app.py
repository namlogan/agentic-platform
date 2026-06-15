from fastapi.testclient import TestClient
from hello_app import app

client = TestClient(app)

def test_hello():
    response = client.get('/hello')
    assert response.status_code == 200
    assert response.json() == {'message': 'Hello from agentic-platform'}

def test_health():
    response = client.get('/health')
    assert response.status_code == 200
    assert response.json() == {'status': 'ok'}

def test_ping():
    response = client.get('/ping')
    assert response.status_code == 200
    assert response.json() == {'ping': 'pong'}

def test_bye():
    response = client.get('/bye')
    assert response.status_code == 200
    assert response.json() == {'bye': 'see you'}

def test_goodbye():
    response = client.get('/goodbye')
    assert response.status_code == 200
    assert response.json() == {'message': 'Goodbye from agentic-platform'}
