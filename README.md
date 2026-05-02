# SQL Server AI Triage Framework

AI-powered SQL Server triage tool that detects performance issues and explains root cause using Query Store and DMVs.

---

## 🚀 Overview

This project automates SQL Server performance triage by:

- Detecting issues using Query Store and DMVs
- Converting findings into structured JSON
- Using AI to explain root cause and next steps
- Generating readable Markdown triage reports

---

## 🧱 Architecture

SQL Server (Query Store + DMVs)  
→ T-SQL Detectors (.sql)  
→ JSON Output  
→ PowerShell Runner  
→ OpenAI API  
→ Markdown Reports  

---

## 🔍 Current Detectors

- **01 – Query Store Plan Regression**  
  Detects plan instability and compares best vs worst plans

- **02 – Blocking**  
  Detects active blocking chains and long waits

- **03 – Memory Grants / RESOURCE_SEMAPHORE**  
  Detects memory pressure, large grants, and wasted memory

- **04 – Top CPU Queries**  
  Identifies high CPU queries and workload hotspots

- **05 – Wait Stats (in progress / optional)**  
  Surfaces top waits impacting performance

---

## 🧠 What It Finds

- Plan regressions (40x slower, 400x CPU, 1000x reads)
- High CPU queries
- Memory grant pressure
- Blocking issues
- Performance hotspots across workloads

---

## ⚙️ How It Works

1. PowerShell runs all detector scripts
2. Each detector:
   - Returns JSON (or nothing if no issue)
3. PowerShell:
   - Generates IssueKey
   - Calculates SeverityScore
   - Suppresses duplicate noise (history tracking)
4. High-value issues are sent to AI
5. Markdown triage reports are generated

---

## 📁 Project Structure
