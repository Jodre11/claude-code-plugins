## Housekeeper Findings

### Finding — Serilog behind latest GA
- **File:** Directory.Packages.props:3
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** Serilog is at 2.10.0; latest GA is 4.3.1.
- **Suggested fix:** Upgrade Serilog to 4.3.1.

### Finding — WindowsAzure.Storage marked deprecated
- **File:** Directory.Packages.props:4
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** housekeeper/nuget
- **Description:** WindowsAzure.Storage is at 9.3.3; latest GA is 9.3.3. Marked deprecated in the registry: Please note, this package is obsolete as of 3/31/2023 and is no longer maintained or monitored. Microsoft encourages you to upgrade to the replacement package, Azure.Storage.Common, to continue receiving updates. Refer to our deprecation policy (https://aka.ms/azsdk/support-policies) for more details.
- **Suggested fix:** Review: WindowsAzure.Storage is current but marked deprecated.
