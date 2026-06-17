"""Audit report builder."""

from dataclasses import dataclass
from typing import Sequence


@dataclass
class AuditRecord:
    """Single row in an audit log."""

    event_id: str
    actor: str
    actor_email: str
    actor_department: str
    action: str
    action_category: str
    resource_type: str
    resource_id: str
    resource_name: str
    outcome: str
    outcome_code: str
    timestamp: str
    duration_ms: int
    source_ip: str
    user_agent: str
    session_id: str
    tenant_id: str
    tenant_name: str
    region: str
    datacenter: str


def build_audit_report(records: Sequence[AuditRecord], title: str = "AUDIT REPORT") -> str:
    """Render a plain-text audit report for the given records.

    Each record produces a fixed-width block with all twenty fields
    labelled and padded to a consistent column width for operator
    review.  The function is intentionally written as one sequential
    pass over the records so the output order matches the input order
    exactly.  No branching on field content — every field is always
    included so the layout is predictable for downstream parsers.
    """
    col = 20
    separator = "-" * 80
    lines: list[str] = []

    lines.append(title)
    lines.append(separator)
    lines.append(f"{'Records'.ljust(col)}: {len(records)}")
    lines.append(separator)

    for record in records:
        event_id_label        = "Event ID".ljust(col)
        actor_label           = "Actor".ljust(col)
        actor_email_label     = "Actor email".ljust(col)
        actor_dept_label      = "Actor department".ljust(col)
        action_label          = "Action".ljust(col)
        action_cat_label      = "Action category".ljust(col)
        res_type_label        = "Resource type".ljust(col)
        res_id_label          = "Resource ID".ljust(col)
        res_name_label        = "Resource name".ljust(col)
        outcome_label         = "Outcome".ljust(col)
        outcome_code_label    = "Outcome code".ljust(col)
        timestamp_label       = "Timestamp".ljust(col)
        duration_label        = "Duration ms".ljust(col)
        source_ip_label       = "Source IP".ljust(col)
        user_agent_label      = "User agent".ljust(col)
        session_id_label      = "Session ID".ljust(col)
        tenant_id_label       = "Tenant ID".ljust(col)
        tenant_name_label     = "Tenant name".ljust(col)
        region_label          = "Region".ljust(col)
        datacenter_label      = "Datacenter".ljust(col)

        lines.append(f"{event_id_label}: {record.event_id}")
        lines.append(f"{actor_label}: {record.actor}")
        lines.append(f"{actor_email_label}: {record.actor_email}")
        lines.append(f"{actor_dept_label}: {record.actor_department}")
        lines.append(f"{action_label}: {record.action}")
        lines.append(f"{action_cat_label}: {record.action_category}")
        lines.append(f"{res_type_label}: {record.resource_type}")
        lines.append(f"{res_id_label}: {record.resource_id}")
        lines.append(f"{res_name_label}: {record.resource_name}")
        lines.append(f"{outcome_label}: {record.outcome}")
        lines.append(f"{outcome_code_label}: {record.outcome_code}")
        lines.append(f"{timestamp_label}: {record.timestamp}")
        lines.append(f"{duration_label}: {record.duration_ms}")
        lines.append(f"{source_ip_label}: {record.source_ip}")
        lines.append(f"{user_agent_label}: {record.user_agent}")
        lines.append(f"{session_id_label}: {record.session_id}")
        lines.append(f"{tenant_id_label}: {record.tenant_id}")
        lines.append(f"{tenant_name_label}: {record.tenant_name}")
        lines.append(f"{region_label}: {record.region}")
        lines.append(f"{datacenter_label}: {record.datacenter}")
        lines.append(separator)

    lines.append(f"{'End of report'.ljust(col)}: {title}")

    return "\n".join(lines)
