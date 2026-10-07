#!/usr/bin/env python3
"""Surgical tip: preserve CANCEL Reason on OpenSIPS 3.6 (pass-reason-hdr)."""
from pathlib import Path
import sys

CFG = Path("/etc/opensips/opensips.cfg")
text = CFG.read_text()

old = """    # ---- Handle CANCEL early (before domain check) ----
    # CANCEL needs to match existing INVITE transaction
    if (is_method("CANCEL")) {
        xlog("CANCEL received from $si:$sp for Call-ID: $hdr(Call-ID), CSeq=$hdr(CSeq), From=$fu, To=$tu\\n");
        # Check if there's a matching transaction
        if (t_check_trans()) {
            xlog("CANCEL matches existing transaction, forwarding to cancel INVITE\\n");
        } else {
            xlog("L_WARN", "CANCEL received but no matching transaction found\\n");
            sl_send_reply(481, "Call/Transaction Does Not Exist");
            exit;
        }
        # Forward CANCEL to cancel the INVITE transaction
        route(RELAY);
        exit;
    }"""

new = """    # ---- Handle CANCEL early (before domain check) ----
    # CANCEL needs to match existing INVITE transaction.
    # t_relay("pass-reason-hdr"): preserve inbound Reason (Asterisk Dial c /
    # Queue C → SIP;cause=200 "Call completed elsewhere"). Plain t_relay()
    # rewrites Reason to SIP;cause=487 "ORIGINATOR_CANCEL", which Snom/Yealink
    # log as missed ("originator cancel"). OpenSIPS 3.6 tm: pass-reason-hdr
    # (legacy hex 0x08 is rejected by named-flags fixup).
    if (is_method("CANCEL")) {
        xlog("CANCEL received from $si:$sp for Call-ID: $hdr(Call-ID), CSeq=$hdr(CSeq), From=$fu, To=$tu Reason=$hdr(Reason)\\n");
        if (t_check_trans()) {
            xlog("CANCEL matches existing transaction, relaying with pass-reason-hdr\\n");
            if (!t_relay("pass-reason-hdr")) {
                xlog("L_ERR", "t_relay(pass-reason-hdr) failed for CANCEL Call-ID=$hdr(Call-ID)\\n");
            }
        } else {
            xlog("L_WARN", "CANCEL received but no matching transaction found\\n");
            sl_send_reply(481, "Call/Transaction Does Not Exist");
        }
        exit;
    }"""

if old not in text:
    print("CANCEL block not found exactly — abort", file=sys.stderr)
    idx = text.find("Handle CANCEL early")
    print(repr(text[idx : idx + 600]) if idx >= 0 else "no CANCEL marker", file=sys.stderr)
    sys.exit(1)

CFG.write_text(text.replace(old, new, 1))
print("patched OK")
