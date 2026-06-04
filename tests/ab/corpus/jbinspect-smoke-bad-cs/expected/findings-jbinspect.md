## JetBrains InspectCode Findings

### Finding — redundant using directive
- **File:** BadCode.cs:2
- **Confidence:** 100
- **Severity:** Important
- **Rule:** RedundantUsingDirective (Redundancies in Code)
- **Description:** Redundant using directive
- **Suggested fix:** Remove the `using` directive on line 2 — nothing in the file references the namespace it imports. The directive is not required by the code and can be safely removed.

### Finding — possible null reference
- **File:** BadCode.cs:11
- **Confidence:** 100
- **Severity:** Important
- **Rule:** PossibleNullReferenceException (Potential Code Quality Issues)
- **Description:** Possible 'System.NullReferenceException'
- **Suggested fix:** The expression dereferenced on line 11 may be null at this point. Guard with a null check before dereferencing, or restructure so a null value cannot reach this line.

### Finding — unused private member
- **File:** BadCode.cs:14
- **Confidence:** 100
- **Severity:** Important
- **Rule:** UnusedMember.Local (Redundancies in Symbol Declarations)
- **Description:** Type member is never used: Private accessibility
- **Suggested fix:** Method `UnusedHelper` on line 14 is never called. Remove it, or wire it into the call path it was written for.
