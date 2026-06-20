from fastapi import FastAPI
from datetime import datetime

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

@app.get('/project-status')
def project_status():
    # Mock status information - in a real implementation this would check actual services
    services = {
        "api": "running",
        "database": "healthy", 
        "cache": "operational",
        "scheduler": "active"
    }
    
    return {
        'status': 'ok',
        'timestamp': datetime.now().isoformat(),
        'services': services
    }
