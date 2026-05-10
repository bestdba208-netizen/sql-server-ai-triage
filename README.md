# SQL Server AI Triage Framework

AI-assisted SQL Server performance triage framework that detects production issues using Query Store and DMVs, then generates structured AI-driven analysis and Markdown reports.

---

# 🚀 Overview

SQL Server AI Triage Framework is designed to accelerate SQL Server performance investigations by combining:

- Deterministic SQL Server diagnostics
- Structured JSON outputs
- PowerShell orchestration
- AI-assisted root cause analysis
- Markdown-based triage reporting

The framework focuses on identifying high-value production issues such as:

- Query Store plan regressions
- Blocking chains
- RESOURCE_SEMAPHORE memory pressure
- High CPU workloads
- Wait statistic anomalies
- Query performance hotspots

Rather than replacing DBA expertise, the framework is intended to help standardize and accelerate the initial triage process.

---

# 🧱 Architecture

```text
SQL Server (Query Store + DMVs)
        ↓
T-SQL Detector Scripts (.sql)
        ↓
Structured JSON Output
        ↓
PowerShell Orchestration Layer
        ↓
OpenAI API Analysis
        ↓
Markdown Triage Reports
```

---

# 🔍 Current Detectors

## 01 – Query Store Plan Regression
Detects plan instability and compares best vs worst execution plans.

### Examples
- 40x slower plan regressions
- Excessive logical reads
- CPU spikes caused by plan changes
- Parameter sniffing indicators

---

## 02 – Blocking
Detects active blocking chains and long-running waits.

### Examples
- Head blockers
- Long-running transactions
- Lock escalation scenarios
- Session wait analysis

---

## 03 – Memory Grants / RESOURCE_SEMAPHORE
Detects memory pressure and inefficient query memory usage.

### Examples
- Excessive memory grants
- Wasted grant memory
- RESOURCE_SEMAPHORE waits
- Spill indicators

---

## 04 – Top CPU Queries
Identifies workload hotspots and CPU-intensive queries.

### Examples
- High cumulative CPU queries
- Sudden CPU spikes
- Expensive procedures
- Repeated high-cost executions

---

## 05 – Wait Stats (In Progress)
Surfaces server-wide wait patterns affecting performance.

### Planned Examples
- PAGEIOLATCH waits
- CXPACKET / CXCONSUMER
- WRITELOG
- SOS_SCHEDULER_YIELD
- ASYNC_NETWORK_IO

---

# 🧠 What the Framework Detects

- Query Store regressions
- Blocking chains
- Memory grant pressure
- High CPU workloads
- Performance bottlenecks
- Wait statistic anomalies
- Query instability
- Production workload hotspots

---

# ⚙️ How It Works

## Step 1 – Detector Execution
PowerShell executes all detector scripts against the target SQL Server instance.

Each detector:

- Returns structured JSON findings
- Returns nothing if no issue is detected
- Focuses on deterministic SQL-based analysis

---

## Step 2 – Issue Normalization
The PowerShell orchestration layer:

- Generates IssueKey values
- Calculates SeverityScore values
- Suppresses duplicate alert noise
- Tracks issue history over time

---

## Step 3 – AI Analysis
High-value findings are submitted to the OpenAI API.

AI-generated analysis may include:

- Root cause summaries
- Triage recommendations
- Performance interpretation
- Potential remediation steps
- Investigation guidance

---

## Step 4 – Markdown Report Generation
Readable Markdown triage reports are generated for:

- Incident review
- DBA triage
- Operational visibility
- Historical tracking
- Knowledge sharing

---

# 📁 Project Structure

```text
/sql
    01-QueryStorePlanRegression.sql
    02-Blocking.sql
    03-MemoryGrants.sql
    04-TopCpuQueries.sql
    05-WaitStats.sql

/scripts
    Invoke-SqlAiTriage.ps1

/reports
    *.md

/logs
    *.log
```

---

# 📄 Example Triage Output

## Detector
Query Store Plan Regression

## Issue Detected
Query execution duration increased from 120ms to 4.8s after a plan change.

## AI Summary
Possible parameter sniffing regression caused by a plan change resulting in significantly increased logical reads and CPU usage.

## Suggested Investigation
- Review Query Store execution plans
- Compare estimated vs actual rows
- Evaluate indexing strategy
- Consider Query Store plan forcing
- Review recent statistics updates

---

# 🛠 Technologies Used

- SQL Server Query Store
- Dynamic Management Views (DMVs)
- PowerShell
- Azure/OpenAI APIs
- JSON
- Markdown Reporting

---

# 🎯 Goals

The goal of the framework is to:

- Reduce triage time
- Improve operational visibility
- Standardize SQL Server diagnostics
- Reduce alert fatigue
- Provide actionable investigation guidance
- Assist DBAs during production incidents

---

# ⚠️ Current Status

This project is currently:

- Experimental
- Under active development
- Intended for lab/testing/learning environments
- Not yet production hardened

The framework is being iteratively expanded with additional detectors, scoring logic, and reporting capabilities.

---

# 🗺 Roadmap

Planned enhancements include:

- Execution plan XML analysis
- Deadlock detection
- TempDB pressure detection
- SQL Agent failure analysis
- Index usage anomaly detection
- Historical trend baselines
- Automatic issue correlation
- HTML dashboard reporting
- Multi-server orchestration

---

# 🤝 Contributing

Suggestions, ideas, and feedback are welcome.

Future goals may include:

- Additional detectors
- Expanded AI analysis capabilities
- Community-contributed triage modules
- Extended reporting functionality

---

# 📜 License

MIT License

---

# 👤 Author

Jeremy Hale

- LinkedIn: https://www.linkedin.com/in/jeremy-h-03aab0296
- GitHub: https://github.com/bestdba208-netizen

