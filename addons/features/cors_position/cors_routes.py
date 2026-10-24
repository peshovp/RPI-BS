from flask import Blueprint, jsonify, request
from flask_login import login_required
from . import cors_api

cors_bp = Blueprint("cors", __name__, url_prefix="/api/cors")


def _respond(result):
    status, body = result
    resp = jsonify(body)
    resp.status_code = status
    resp.headers["Cache-Control"] = "no-store"
    return resp


@cors_bp.route("/accounts", methods=["GET"])
@login_required
def list_accounts_route():
    return _respond(cors_api.handle_list())


@cors_bp.route("/accounts", methods=["POST"])
@login_required
def create_account_route():
    return _respond(cors_api.handle_create(request.get_json(silent=True)))


@cors_bp.route("/accounts/<account_id>", methods=["PUT"])
@login_required
def update_account_route(account_id):
    return _respond(cors_api.handle_update(account_id, request.get_json(silent=True)))


@cors_bp.route("/accounts/<account_id>", methods=["DELETE"])
@login_required
def delete_account_route(account_id):
    return _respond(cors_api.handle_delete(account_id))


@cors_bp.route("/accounts/<account_id>/compute", methods=["POST"])
@login_required
def compute_route(account_id):
    return _respond(cors_api.handle_compute(account_id))


@cors_bp.route("/job", methods=["GET"])
@login_required
def job_route():
    return _respond(cors_api.handle_job())


@cors_bp.route("/job/cancel", methods=["POST"])
@login_required
def cancel_route():
    return _respond(cors_api.handle_cancel())


@cors_bp.route("/job/apply", methods=["POST"])
@login_required
def apply_route():
    return _respond(cors_api.handle_apply(request.get_json(silent=True)))
