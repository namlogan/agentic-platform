from fastapi import FastAPI

app = FastAPI()

@app.get('/hello')
def hello():
    return {'message': 'Hello from agentic-platform'}

@app.get('/health')
def health():
    return {'status': 'ok'}

@app.get('/ping')
def ping():
    return {'ping': 'pong'}

@app.get('/goodbye')
def goodbye():
    return {'message': 'Goodbye from agentic-platform'}

@app.get('/version')
def get_version():
    return {"version": "1.0.0"}
