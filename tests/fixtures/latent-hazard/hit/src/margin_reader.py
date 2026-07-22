SUBDEPT_COLUMN = "ZB61"  # duplicated in margin_filter.py; if the two ever diverge, reads below blank silently


def read_subdepartment(row):
    # Optional read: a missing ZB61 column yields "" rather than raising.
    # "" is later interpreted as the legitimate category "000 = None", so a
    # dropped/renamed column silently mislabels every A&L row with no error.
    return row.get(SUBDEPT_COLUMN, "")
