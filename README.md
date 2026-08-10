## SonarQube Analysis Strategy for Multi-Language Repositories

### 1. Do multiple programming languages require multiple SonarQube executions?

**No.**

The number of programming languages in a repository does **not** determine the number of SonarQube projects or analysis executions.

A single SonarQube project and a single analysis can cover multiple supported languages when they belong to the same logical application/component.

For example:

```text
Repository
├── Backend        → C#
├── Frontend       → TypeScript / HTML / CSS
├── Infrastructure → Terraform
└── Pipelines      → YAML
```

If these components belong to the same application, the recommended approach is:

```text
1 Repository
1 SonarQube Project
1 SonarQube Analysis
Multiple language analyzers
```

The scanner will identify and analyze the supported languages within the configured analysis scope.

---

### 2. When are multiple SonarQube executions required?

Multiple executions are required when the repository contains **multiple independent SonarQube projects/components** that need to be analyzed separately.

The most common example is a monorepo:

```text
Repository
├── Service A → SonarQube Project A
├── Service B → SonarQube Project B
└── Service C → SonarQube Project C
```

The pipeline should then perform an independent analysis for each project:

```text
Prepare A → Build A → Analyze A

Prepare B → Build B → Analyze B

Prepare C → Build C → Analyze C
```

The decision should therefore be based on **software/component boundaries**, not programming-language boundaries.

Multiple SonarQube projects may be appropriate when components have:

* Independent build/deployment lifecycles
* Different ownership
* Independent Quality Gates
* Independent release processes
* Different security or quality governance requirements

A monorepo does **not** automatically require multiple SonarQube projects. If the repository represents one logical application, a single project may still be appropriate.

---

### 3. Multi-language configuration

For current **SonarScanner for .NET** versions, multi-language analysis is enabled by default.

Therefore, it is generally **not necessary to explicitly configure**:

```text
sonar.scanner.scanAll=true
```

The recommended approach is to rely on the default behavior and only configure `scanAll=false` when there is a specific requirement to restrict the analysis scope.

For example, if unwanted files are being analyzed, it is generally preferable to control the scope using exclusions such as:

```text
sonar.exclusions=**/node_modules/**,**/bin/**,**/obj/**,**/dist/**
```

rather than disabling multi-language analysis globally.

`sonar.scanner.scanAll` is therefore **not a mandatory "multi-language switch"** that should be added to every pipeline.

---

### 4. Scanner selection

The scanner should be selected based primarily on the project's build ecosystem:

| Project / Build Type                             | Recommended Scanner                |
| ------------------------------------------------ | ---------------------------------- |
| .NET / MSBuild                                   | SonarScanner for .NET              |
| Maven                                            | SonarScanner for Maven             |
| Gradle                                           | SonarScanner for Gradle            |
| JavaScript / TypeScript                          | SonarScanner CLI / NPM integration |
| Python                                           | SonarScanner CLI                   |
| Go                                               | SonarScanner CLI                   |
| Terraform / configuration repositories           | SonarScanner CLI                   |
| Mixed repository without a dominant build system | SonarScanner CLI                   |

When a specialized scanner exists, it should generally be preferred because it can obtain build-specific information required for a more complete analysis.

---

### 5. Recommended decision rule

The organizational standard should be:

> **Do not create one SonarQube project per programming language. Create SonarQube projects according to logical software/component boundaries.**

Therefore:

```text
One logical application
        ↓
One SonarQube project
        ↓
One analysis execution
        ↓
Multiple supported language analyzers
```

Whereas:

```text
Multiple independent applications/services
        ↓
Multiple SonarQube projects
        ↓
Multiple independent analysis executions
```

The key distinction is:

```text
Number of languages
        ≠
Number of SonarQube executions

Number of independent software components
        →
SonarQube project boundaries
        →
Analysis execution boundaries
```

### References

* SonarScanner for .NET: https://docs.sonarsource.com/sonarqube-server/analyzing-source-code/scanners/dotnet/
* Azure DevOps SonarQube tasks: https://docs.sonarsource.com/sonarqube-server/devops-platform-integration/azure-devops-integration/adding-analysis-to-pipeline/sonarqube-tasks
* Azure DevOps monorepo analysis: https://docs.sonarsource.com/sonarqube-server/devops-platform-integration/azure-devops-integration/adding-analysis-to-pipeline/monorepo-projects
