from fastapi import FastAPI

app = FastAPI()

@app.get('/hello')
def hello():
    return {'message': 'Hello from agentic-platform'}

@app.get('/health')
def health():
    return {'status': 'ok'}

@app.get('/goodbye')
def goodbye():
    return {'message': 'Goodbye from agentic-platform'}
