SUBDEPT_COLUMN = "ZB61"


def read_subdepartment(row):
    # Required read: a missing column raises loudly. Not silent, so out of
    # latent-hazard's scope — this is the inflation guard.
    if SUBDEPT_COLUMN not in row:
        raise KeyError(f"required column {SUBDEPT_COLUMN} absent")
    return row[SUBDEPT_COLUMN]
