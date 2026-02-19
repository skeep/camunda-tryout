"""
Camunda External Task Mock Worker

A single-process worker that polls all external task topics defined in the
Auto Loan Email Intake workflow and completes them with configurable mock
responses.  Designed to run as a Docker container alongside Camunda.

Usage:
    python worker.py                  # uses defaults / env vars
    MOCK_IS_READABLE=false python worker.py   # simulate unreadable doc
"""

import logging
import os
import signal
import sys
import time

import requests

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
CAMUNDA_REST_URL = os.getenv("CAMUNDA_REST_URL", "http://camunda:8080/engine-rest")
WORKER_ID = os.getenv("WORKER_ID", "mock-worker-001")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "2"))
LOCK_DURATION = int(os.getenv("LOCK_DURATION", "30000"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "5"))
RETRY_BACKOFF = int(os.getenv("RETRY_BACKOFF", "5"))

# Per-topic behaviour overrides
MOCK_IS_READABLE = os.getenv("MOCK_IS_READABLE", "true").lower() == "true"
MOCK_IS_DUPLICATE = os.getenv("MOCK_IS_DUPLICATE", "false").lower() == "true"
MOCK_AUTO_COG_RESPONSE = os.getenv("MOCK_AUTO_COG_RESPONSE", "true").lower() == "true"
MOCK_COG_DELAY = int(os.getenv("MOCK_COG_DELAY", "3"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("mock-worker")

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
_running = True


def _shutdown(signum, _frame):
    global _running
    sig_name = signal.Signals(signum).name
    log.info("Received %s – shutting down gracefully …", sig_name)
    _running = False


signal.signal(signal.SIGINT, _shutdown)
signal.signal(signal.SIGTERM, _shutdown)

# ---------------------------------------------------------------------------
# Topic handler registry
#
# Each handler returns the variables dict to send back when completing the
# external task.  The handler receives the full task payload so it can
# inspect process variables if needed.
# ---------------------------------------------------------------------------


def _handle_send_notification(task):
    """Mock: log the notification type and mark as sent."""
    variables = task.get("variables", {})
    notif_type = variables.get("notificationType", {}).get("value", "UNKNOWN")
    log.info("  -> Sending notification: %s (mock)", notif_type)
    return {"notificationSent": {"value": True, "type": "Boolean"}}


def _handle_resume_loan_processing(task):
    """Mock: mark loan processing as resumed."""
    log.info("  -> Resuming loan processing (mock)")
    return {"resumed": {"value": True, "type": "Boolean"}}


def _handle_route_to_next_stage(task):
    """Mock: route to next stage (Rule 3 placeholder)."""
    log.info("  -> Routing to next stage (mock)")
    return {"routed": {"value": True, "type": "Boolean"}}


def _handle_archive_case(task):
    """Mock: archive the closed case."""
    log.info("  -> Archiving case – terminal closure (mock)")
    return {"archived": {"value": True, "type": "Boolean"}}


def _handle_assess_readability(task):
    """Mock: AI readability check – configurable via MOCK_IS_READABLE."""
    log.info("  -> Assessing readability: isReadable=%s (mock)", MOCK_IS_READABLE)
    return {"isReadable": {"value": MOCK_IS_READABLE, "type": "Boolean"}}


def _handle_check_duplicate(task):
    """Mock: duplicate application check – configurable via MOCK_IS_DUPLICATE."""
    log.info("  -> Checking duplicates: isDuplicate=%s (mock)", MOCK_IS_DUPLICATE)
    result = {
        "isDuplicate": {"value": MOCK_IS_DUPLICATE, "type": "Boolean"},
    }
    if MOCK_IS_DUPLICATE:
        result["matchedApplicationId"] = {
            "value": "MOCK-DUP-12345",
            "type": "String",
        }
    return result


def _handle_send_cog_email(task):
    """Mock: send email to COG mailbox with CC to Sales Officer and MA."""
    log.info("  -> Sending COG email (mock) – CC: Sales Officer, MA")
    log.info("     Attaching original files (mock)")
    return {"cogEmailSent": {"value": True, "type": "Boolean"}}


def _handle_extract_borrower_data(task):
    """Mock: extract and normalize borrower data from documents."""
    log.info("  -> Extracting borrower data (mock)")
    return {
        "borrowerFirstName": {"value": "John", "type": "String"},
        "borrowerLastName": {"value": "Doe", "type": "String"},
        "borrowerSSN": {"value": "***-**-1234", "type": "String"},
        "loanAmount": {"value": 25000, "type": "Long"},
        "collateralVIN": {"value": "1HGCM82633A004352", "type": "String"},
        "refereeId": {"value": "REF-MOCK-001", "type": "String"},
        "sourceChannel": {"value": "email", "type": "String"},
        "dataExtracted": {"value": True, "type": "Boolean"},
    }


def _handle_notify_duplicate(task):
    """Mock: notify Sales Officer about duplicate application."""
    variables = task.get("variables", {})
    matched_id = variables.get("matchedApplicationId", {}).get("value", "UNKNOWN")
    log.info("  -> Notifying Sales Officer of duplicate (matchedId=%s) (mock)", matched_id)
    return {"duplicateNotified": {"value": True, "type": "Boolean"}}


TOPIC_HANDLERS = {
    "sendNotification": _handle_send_notification,
    "resumeLoanProcessing": _handle_resume_loan_processing,
    "routeToNextStage": _handle_route_to_next_stage,
    "archiveCase": _handle_archive_case,
    "assessReadability": _handle_assess_readability,
    "checkDuplicateApplication": _handle_check_duplicate,
    "sendCogEmail": _handle_send_cog_email,
    "extractBorrowerData": _handle_extract_borrower_data,
    "notifyDuplicate": _handle_notify_duplicate,
}

# ---------------------------------------------------------------------------
# Core loop
# ---------------------------------------------------------------------------


def _wait_for_camunda():
    """Block until the Camunda REST API is reachable."""
    attempt = 0
    while _running:
        attempt += 1
        try:
            resp = requests.get(f"{CAMUNDA_REST_URL}/engine", timeout=5)
            if resp.status_code == 200:
                log.info("Camunda REST API is reachable at %s", CAMUNDA_REST_URL)
                return True
        except requests.ConnectionError:
            pass
        backoff = min(RETRY_BACKOFF * attempt, 30)
        log.warning(
            "Camunda not ready (attempt %d) – retrying in %ds …", attempt, backoff
        )
        time.sleep(backoff)
    return False


def _fetch_and_lock():
    """Fetch external tasks for all registered topics."""
    topics = [
        {"topicName": name, "lockDuration": LOCK_DURATION}
        for name in TOPIC_HANDLERS
    ]
    try:
        resp = requests.post(
            f"{CAMUNDA_REST_URL}/external-task/fetchAndLock",
            json={
                "workerId": WORKER_ID,
                "maxTasks": 10,
                "topics": topics,
            },
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as exc:
        log.error("fetchAndLock failed: %s", exc)
        return []


def _complete_task(task, variables):
    """Complete an external task with the given variables."""
    task_id = task["id"]
    try:
        resp = requests.post(
            f"{CAMUNDA_REST_URL}/external-task/{task_id}/complete",
            json={
                "workerId": WORKER_ID,
                "variables": variables,
            },
            timeout=10,
        )
        resp.raise_for_status()
        log.info("  -> Completed task %s", task_id)
    except requests.RequestException as exc:
        log.error("  -> Failed to complete task %s: %s", task_id, exc)


def _send_cog_form_message(process_instance_id):
    """Auto-send CogFormSubmitted message to resume the process after COG email.

    This simulates the MS Forms integration that would normally trigger
    when the COG team submits the encoded form.
    """
    log.info(
        "  -> Auto-sending CogFormSubmitted message to process %s (delay=%ds)",
        process_instance_id,
        MOCK_COG_DELAY,
    )
    time.sleep(MOCK_COG_DELAY)
    try:
        resp = requests.post(
            f"{CAMUNDA_REST_URL}/message",
            json={
                "messageName": "CogFormSubmitted",
                "processInstanceId": process_instance_id,
            },
            timeout=10,
        )
        resp.raise_for_status()
        log.info(
            "  -> CogFormSubmitted message delivered to process %s",
            process_instance_id,
        )
    except requests.RequestException as exc:
        log.error(
            "  -> Failed to deliver CogFormSubmitted to process %s: %s",
            process_instance_id,
            exc,
        )


def main():
    log.info("=" * 60)
    log.info("Camunda External Task Mock Worker")
    log.info("=" * 60)
    log.info("  REST URL      : %s", CAMUNDA_REST_URL)
    log.info("  Worker ID     : %s", WORKER_ID)
    log.info("  Poll interval : %ds", POLL_INTERVAL)
    log.info("  Lock duration : %dms", LOCK_DURATION)
    log.info("  Topics        : %s", ", ".join(TOPIC_HANDLERS.keys()))
    log.info("  MOCK_IS_READABLE      : %s", MOCK_IS_READABLE)
    log.info("  MOCK_IS_DUPLICATE     : %s", MOCK_IS_DUPLICATE)
    log.info("  MOCK_AUTO_COG_RESPONSE: %s", MOCK_AUTO_COG_RESPONSE)
    log.info("  MOCK_COG_DELAY        : %ds", MOCK_COG_DELAY)
    log.info("=" * 60)

    if not _wait_for_camunda():
        log.error("Aborted – Camunda never became reachable.")
        sys.exit(1)

    log.info("Starting poll loop (Ctrl+C to stop) …")

    while _running:
        tasks = _fetch_and_lock()

        for task in tasks:
            topic = task.get("topicName", "?")
            task_id = task.get("id", "?")
            process_instance = task.get("processInstanceId", "?")
            log.info(
                "Fetched task  topic=%-28s  id=%s  process=%s",
                topic,
                task_id,
                process_instance,
            )

            handler = TOPIC_HANDLERS.get(topic)
            if handler:
                variables = handler(task)
                _complete_task(task, variables)

                if topic == "sendCogEmail" and MOCK_AUTO_COG_RESPONSE:
                    _send_cog_form_message(process_instance)
            else:
                log.warning("No handler for topic '%s' – skipping", topic)

        time.sleep(POLL_INTERVAL)

    log.info("Worker stopped.")


if __name__ == "__main__":
    main()
