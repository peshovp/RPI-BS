# GeoMaxima Features

This directory contains modular feature implementations for GeoMaxima.

## Creating a New Feature

1. **Create a new Python file** in this directory (e.g., `my_feature.py`)

2. **Implement the feature**:
```python
from flask import jsonify
import logging

logger = logging.getLogger(__name__)

def register_routes(app, gm_blueprint):
    """Register routes for your feature"""
    
    @gm_blueprint.route('/api/my-feature')
    def my_feature():
        return jsonify({"status": "ok", "message": "My feature works!"})
    
    logger.info("My feature routes registered")
```

3. **Enable the feature** in `geomaxima/config.py`:
```python
FEATURES = {
    "my_feature": True,  # Add this line
}
```

4. **Restart the web service**:
```bash
sudo systemctl restart rtkbase_web
```

## Feature Structure

Each feature module should:
- Have a `register_routes(app, gm_blueprint)` function
- Optionally have an `initialize(app)` function for setup
- Optionally have a `cleanup()` function for teardown
- Use proper logging

## Available Features

- **example_feature.py** - Example implementation showing basic patterns

## Best Practices

1. **Naming**: Use descriptive names with underscores (e.g., `data_export.py`)
2. **Logging**: Use the logging module, not print statements
3. **Error Handling**: Wrap risky operations in try-except blocks
4. **API Routes**: Follow REST conventions
5. **Documentation**: Add docstrings to functions

## Feature Dependencies

If your feature needs additional Python packages:
1. Add them to a `requirements-geomaxima.txt` file
2. Install with: `pip install -r geomaxima/requirements-geomaxima.txt`
