SUBDEPT_COLUMN = "ZB61"


def is_al_row(row):
    # Rows are classified A&L by the sub-department column; this key must stay
    # in sync with margin_reader.SUBDEPT_COLUMN — if the two ever diverge, the
    # optional read in margin_reader silently blanks every row.
    return row.get(SUBDEPT_COLUMN, "") != ""
