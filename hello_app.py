# In a file called hello_app.py
from fastapi import FastAPI

def hello():
    return {'message': 'Hello from agentic-platform'}

app = FastAPI()
@app.get('/hello')
def hello():
    return {'message': 'Hello from agentic-platform'}