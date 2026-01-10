# GeminiOS Shell Test Suite

Run these commands in the `ginit` shell to verify functionality.

## 1. Output Redirection

### 1.1 Overwrite (`>`)
**Command:**
```bash
echo "Hello World" > /tmp/test_out.txt
cat /tmp/test_out.txt
```
**Expected Output:**
```
Hello World
```

### 1.2 Append (`>>`)
**Command:**
```bash
echo "Second Line" >> /tmp/test_out.txt
cat /tmp/test_out.txt
```
**Expected Output:**
```
Hello World
Second Line
```

### 1.3 Combined Redirect (`&>`)
**Command:**
```bash
ls /nonexistent &> /tmp/test_both.txt
cat /tmp/test_both.txt
```
**Expected Output:**
```
ls: cannot access '/nonexistent': No such file or directory
```
*(Exact error message may vary, but file should contain the error)*

## 2. Input Redirection

### 2.1 File Input (`<`)
**Command:**
```bash
cat < /tmp/test_out.txt
```
**Expected Output:**
```
Hello World
Second Line
```

### 2.2 Here-Document (`<<`)
**Command:**
```bash
cat << EOF
Line One
Line Two
EOF
```
**Expected Output:**
```
Line One
Line Two
```

### 2.3 Here-String (`<<<`)
**Command:**
```bash
cat <<< "Single String Data"
```
**Expected Output:**
```
Single String Data
```

## 3. Standard Error Redirection

### 3.1 Stderr Only (`2>`)
**Command:**
```bash
ls /nonexistent 2> /tmp/test_err.txt
cat /tmp/test_err.txt
```
**Expected Output:**
```
ls: cannot access...
```

### 3.2 Stderr to Stdout (`2>&1`)
**Command:**
```bash
ls /nonexistent > /tmp/test_merged.txt 2>&1
cat /tmp/test_merged.txt
```
**Expected Output:**
```
ls: cannot access...
```

## 4. Expansions

### 4.1 Variables (`$VAR`)
**Command:**
```bash
export TESTVAR="Success"
echo $TESTVAR
```
**Expected Output:**
```
Success
```

### 4.2 Wildcards (`*`)
**Command:**
```bash
cd /
echo b*
```
**Expected Output:**
```
bin boot
```
*(Assuming /bin and /boot exist)*

## 5. Control Flow

### 5.1 AND (`&&`)
**Command:**
```bash
echo A && echo B
```
**Expected Output:**
```
A
B
```

### 5.2 OR (`||`)
**Command:**
```bash
echo A || echo B
```
**Expected Output:**
```
A
```

## 6. Grouping and Subshells

### 6.1 Subshell (`( ... )`)
**Command:**
```bash
(cd /tmp; echo "In Subshell:"; pwd)
echo "Main Shell:"; pwd
```
**Expected Output:**
```
In Subshell:
/tmp
Main Shell:
/
```
*(Assuming started in /)*

### 6.2 Grouping (`{ ...; }`)
**Command:**
```bash
{ echo Group; echo Block; } > /tmp/group_out.txt
cat /tmp/group_out.txt
```
**Expected Output:**
```
Group
Block
```
