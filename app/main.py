import os
from fastapi import FastAPI
from datetime import datetime

app = FastAPI(
    title="Platform Onboarding Demo API",
    description="Sample workload deployed onto the Azure AKS landing zone.",
    version="1.0.0"
)

@app.get("/health")
def health():
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/info")
def info():
    return {
        "app": "azure-aks-platform-onboarding",
        "environment": os.getenv("ENVIRONMENT", "unknown"),
        "region": os.getenv("AZURE_REGION", "unknown"),
        "version": "1.0.0"
    }

@app.get("/secret-check")
def secret_check():
    secret = os.getenv("DB_PASSWORD")
    return {
        "secret_mounted": secret is not None,
        "source": "Azure Key Vault via workload identity"
    }