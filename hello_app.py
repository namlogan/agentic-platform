from fastapi import FastAPI

app = FastAPI()

@app.get('/hello')
def hello():
    return {'message': 'Hello from agentic-platform'}

@app.get('/health')
def health():
    return {'status': 'ok'}
