
# **PCAI Automation Scripts**

This repository contains simple automation scripts that help with **firewall connectivity checks** and **DNS validation** for PCAI and Developer systems.

These scripts are lightweight and can be run directly on customer worker scs02 node or preferable some other node such as glfs which has access to internet VMs during pre-checks before deployment.

---

## 📁 **Repository Structure**

```
pcai-automation/
│
├── firewall.sh               → Firewall connectivity check (TCP-based)
├── dns-check.sh              → DNS forward + reverse lookup validator
├── firewall-pcai-dns.sh      → Combined Firewall + DNS check script
└── input.txt                 → Sample input file for dns-check.sh
```

---

## 🔥 **1. firewall.sh**

This script checks **TCP connectivity** (port 443) to all required URLs for PCAI / Developer systems.

### **Usage**

```bash
bash <(curl -sL "https://github.com/raviteja-panugundla/pcai-automation/raw/main/firewall.sh")
```

It will ask:

* Region (jp1, us1, eu1, etc.)
* System type (pcai / dev)

Based on your selection, it automatically loads the correct rule set:

* **pcai → full list**
* **dev → reduced list**

### **Output**

A clean ✓/✗ summary showing which URLs are reachable.

---

## 🌐 **2. dns-check.sh**

This script performs:

* Forward lookup (FQDN → IP)
* Reverse lookup (IP → PTR → FQDN)
* Comparison to detect mismatches

### **Input File**

`input.txt` contains lines in the format:

```
192.168.1.10 fqdn.example.com
10.0.0.5 node01.customer.local
```

You may replace this with customer data but keep the same structure.

### **Usage**

```bash
bash dns-check.sh input.txt > dns_output.txt
```

The output file is ready to share with Support/Engineering.

---

## 🔥🌐 **3. firewall-pcai-dns.sh**

This is a **combined script** that runs both:

* Firewall connectivity check
* DNS validation

Ideal for **full pre-check** before upgrades / deployments.

### **Usage**

```bash
bash <(curl -sL "https://github.com/raviteja-panugundla/pcai-automation/raw/main/firewall-pcai-dns.sh")
```

You will be prompted for:

* Region
* System Type (pcai/dev)

It also uses `input.txt` for DNS checks.

---

## 📄 **4. input.txt**

Template for DNS testing.

Update this file with actual customer data before running `dns-check.sh` or `firewall-pcai-dns.sh`.

---

## 📦 **Run Directly (curl) in customer worker scs02 node or preferable some other node such as glfs which has access to internet**

Because GitHub **raw.githubusercontent.com** is often blocked in customer sites, use this format:


```bash
bash <(curl -sL "https://github.com/raviteja-panugundla/pcai-automation/raw/main/firewall-pcai-dns.sh")
```

---

## 📝 Notes for Customer / Support Engineers

* These scripts require **bash**.
* They do **not modify** the system (safe to run anywhere).
* Works without sudo.
* Can redirect all outputs like:

```
bash firewall.sh > firewall_report.txt
bash dns-check.sh input.txt > dns_report.txt
bash firewall-pcai-dns.sh > full_precheck.txt
```

