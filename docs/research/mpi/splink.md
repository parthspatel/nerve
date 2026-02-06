# Splink

> Probabilistic record linkage at scale using the Fellegi-Sunter model

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Splink |
| **Organization** | UK Ministry of Justice |
| **Website** | [moj-analytical-services.github.io/splink](https://moj-analytical-services.github.io/splink/) |
| **GitHub** | [moj-analytical-services/splink](https://github.com/moj-analytical-services/splink) (~4.2K stars) |
| **Latest Version** | Splink 4.x (2025) |
| **License** | MIT |
| **Language** | Python |
| **Backends** | DuckDB (local), Spark (distributed), Athena, PostgreSQL |
| **Nerve Role** | Batch probabilistic patient deduplication across the full patient corpus |

---

## What Is It?

Splink is a Python library for probabilistic record linkage (entity resolution) that implements the **Fellegi-Sunter model** with parameter estimation via the **Expectation-Maximization (EM) algorithm**. It requires **no training data** — it learns matching parameters unsupervised from the data itself.

In Nerve, Splink is the **batch component of the hybrid MPI** — running periodically (nightly/weekly) for deeper probabilistic deduplication that catches matches the real-time deterministic engine (HAPI FHIR MDM) might miss.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Splink Pipeline                         │
│                                                           │
│  Step 1: Configure Comparison                             │
│  ┌─────────────────────────────────────────────────┐     │
│  │  Comparison definitions:                          │     │
│  │  • First name: Jaro-Winkler at 0.9, 0.7         │     │
│  │  • Last name: Jaro-Winkler at 0.9, 0.7          │     │
│  │  • DOB: exact, within 1 month, within 1 year     │     │
│  │  • Sex: exact                                     │     │
│  │  • Address: Levenshtein at thresholds             │     │
│  │  • SSN (where available): exact                   │     │
│  └─────────────────────────────────────────────────┘     │
│                                                           │
│  Step 2: Estimate Parameters (EM Algorithm)               │
│  ┌─────────────────────────────────────────────────┐     │
│  │  No training data required!                       │     │
│  │                                                   │     │
│  │  For each comparison:                             │     │
│  │  • m probability: P(agree | true match)           │     │
│  │  • u probability: P(agree | non-match)            │     │
│  │                                                   │     │
│  │  Match weight = log2(m/u)                         │     │
│  │  Higher weight = more discriminating field        │     │
│  └─────────────────────────────────────────────────┘     │
│                                                           │
│  Step 3: Predict Matches                                  │
│  ┌─────────────────────────────────────────────────┐     │
│  │  Blocking rules reduce comparison space:          │     │
│  │  • Same first 3 chars of last name + same DOB    │     │
│  │  • Same last name + same city                     │     │
│  │  • Same SSN                                       │     │
│  │                                                   │     │
│  │  Total match weight = sum of field weights        │     │
│  │  Match probability = 1 / (1 + exp(-weight))       │     │
│  │                                                   │     │
│  │  Threshold: 0.95 = match, 0.5-0.95 = review      │     │
│  └─────────────────────────────────────────────────┘     │
│                                                           │
│  Step 4: Cluster & Visualize                              │
│  ┌─────────────────────────────────────────────────┐     │
│  │  Connected components → patient clusters          │     │
│  │  Interactive charts for match quality review      │     │
│  │  Waterfall charts showing field contributions     │     │
│  │  Precision/recall metrics                         │     │
│  └─────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────┘
```

---

## Scale and Proven Deployments

| Deployment | Records | Organization |
|-----------|---------|--------------|
| **200M+ hospital records** | 200,000,000 | US Defense Health Agency |
| **100M+ records** | 100,000,000 | UK Government (various) |
| **14M+ PyPI downloads** | N/A | Open-source community |
| **NHS** | Millions | UK National Health Service |

The US Defense Health Agency used Splink to deduplicate **200+ million hospital records** — the largest known healthcare MPI deployment.

---

## Nerve-Specific Configuration

```python
import splink
from splink import Linker, SettingsCreator, block_on, DuckDBAPI
# Or for production: from splink import SparkAPI

settings = SettingsCreator(
    link_type="dedupe_only",
    comparisons=[
        # Last name: exact > jaro-winkler 0.9 > 0.7 > else
        splink.ctl.exact_match("last_name"),
        splink.cl.JaroWinklerAtThresholds("last_name", [0.9, 0.7]),

        # First name: exact > jaro-winkler 0.9 > 0.7 > else
        splink.cl.JaroWinklerAtThresholds("first_name", [0.9, 0.7]),

        # Date of birth: exact > within 1 month > within 1 year
        splink.cl.DatediffAtThresholds(
            "date_of_birth",
            date_thresholds=[1, 12],
            date_metrics=["month", "month"]
        ),

        # Sex: exact
        splink.ctl.exact_match("sex"),

        # Address: Levenshtein
        splink.cl.LevenshteinAtThresholds("address_line1", [1, 3]),

        # ZIP code: exact > first 3 digits
        splink.ctl.exact_match("zip_code"),

        # SSN (where available): exact
        splink.ctl.exact_match("ssn_hash"),
    ],
    blocking_rules_to_generate_predictions=[
        block_on("substr(last_name, 1, 3)", "date_of_birth"),
        block_on("last_name", "city"),
        block_on("ssn_hash"),
        block_on("first_name", "zip_code"),
    ],
    retain_intermediate_calculation_columns=True,
)

# For development: DuckDB backend
db_api = DuckDBAPI()
linker = Linker(df_patients, settings, db_api=db_api)

# For production: Spark backend
# spark = SparkSession.builder.appName("nerve-mpi").getOrCreate()
# db_api = SparkAPI(spark_session=spark)
# linker = Linker(spark_df_patients, settings, db_api=db_api)

# Estimate parameters (no training data!)
linker.training.estimate_probability_two_random_records_match(
    [block_on("last_name", "date_of_birth")],
    recall=0.7
)
linker.training.estimate_u_using_random_sampling(max_pairs=1e7)
linker.training.estimate_parameters_using_expectation_maximisation(
    block_on("last_name", "first_name")
)
linker.training.estimate_parameters_using_expectation_maximisation(
    block_on("date_of_birth")
)

# Predict matches
results = linker.inference.predict(threshold_match_probability=0.5)

# Cluster into patient groups
clusters = linker.clustering.cluster_pairwise_predictions_at_threshold(
    results, threshold_match_probability=0.95
)
```

---

## Interactive Visualizations

Splink provides rich visualizations for match quality assurance:

### Match Weight Waterfall Chart
Shows the contribution of each field to the overall match score for a specific pair:

```
Record A: John Doe, 1980-01-01, 123 Main St, Phoenix AZ 85001
Record B: Jon  Doe, 1980-01-01, 123 Main St, Phoenix AZ 85001

Field           Match Weight    Cumulative
───────────────────────────────────────────
Prior           -5.0           -5.0
Last name       +8.2 (exact)   +3.2
First name      +4.5 (JW=0.91)+7.7
DOB             +7.8 (exact)   +15.5
Sex             +0.5 (exact)   +16.0
Address         +6.2 (exact)   +22.2
ZIP             +2.1 (exact)   +24.3
───────────────────────────────────────────
Match probability: 99.97%       ✓ MATCH
```

### Comparison Viewer
Interactive side-by-side comparison of candidate pairs with color-coded field agreements.

### Precision-Recall Curve
Shows trade-off between false positives and false negatives at different thresholds.

### Cluster Visualization
Network graph showing connected patient records and their link strengths.

---

## Integration with HAPI FHIR MDM

```
┌──────────────────────────────────────────────────────┐
│                Nerve MPI Pipeline                      │
│                                                       │
│  Real-Time Path (every ADT message):                  │
│  ADT → Flink → HAPI FHIR MDM → instant match/create │
│                                                       │
│  Batch Path (nightly/weekly):                         │
│  Silver.patients → Splink → match results             │
│       │                          │                     │
│       │                          ▼                     │
│       │                    HAPI FHIR MDM              │
│       │                    POST /$mdm-submit          │
│       │                    (confirm/create links)     │
│       │                          │                     │
│       ▼                          ▼                     │
│  Golden Records updated across all patients           │
│  empi_id propagated to Silver/Gold tables             │
└──────────────────────────────────────────────────────┘
```

Splink results feed back into HAPI FHIR MDM via `$mdm-submit`:
- **High-confidence matches** (>0.95): Auto-linked as MATCH
- **Medium-confidence** (0.5-0.95): Submitted as POSSIBLE_MATCH for manual review
- **New clusters**: Submitted as new golden records

---

## How to Leverage in Nerve

1. **Deep Deduplication**: Catch probabilistic matches that deterministic rules miss (misspellings, name changes, typos)
2. **No Training Data**: EM algorithm learns from the data — no labeled dataset required
3. **Scale to 200M+ Records**: Proven at Defense Health Agency scale on Spark
4. **Match Quality Assurance**: Interactive visualizations for clinical review
5. **Blocking Strategies**: Efficient comparison space reduction for large patient corpora
6. **DuckDB for Development**: Fast local testing without Spark infrastructure
7. **Audit Trail**: Full match weight breakdown for regulatory compliance

---

## Splink vs. Alternatives

| Feature | Splink | dedupe.io | RecordLinkage (R) | OpenEMPI |
|---------|--------|-----------|-------------------|----------|
| **Model** | Fellegi-Sunter | Active learning | Fellegi-Sunter | Rule-based |
| **Training Data** | Not required (EM) | Requires labeling | Not required | Not applicable |
| **Scale** | 200M+ records | Millions | Thousands | Millions |
| **Backend** | DuckDB/Spark/Athena | Python | R | Java/JBoss |
| **License** | MIT | MIT (lib) | BSD-3 | Open (stale) |
| **Visualizations** | Rich interactive | Basic | None | Basic |
| **Last Update** | Active (2025) | Active | Active | Abandoned (~2013) |
| **Healthcare Proven** | US DoD, NHS | General | Academic | Legacy deployments |

---

## Visual References

- **Splink Documentation**: [moj-analytical-services.github.io/splink](https://moj-analytical-services.github.io/splink/) — Full docs with interactive demos
- **Waterfall Charts**: [moj-analytical-services.github.io/splink/demos/examples/duckdb/deduplicate_50k_synthetic.html](https://moj-analytical-services.github.io/splink/demos/examples/duckdb/deduplicate_50k_synthetic.html)
- **Fellegi-Sunter Model**: [moj-analytical-services.github.io/splink/topic_guides/theory/fellegi_sunter.html](https://moj-analytical-services.github.io/splink/topic_guides/theory/fellegi_sunter.html)
- **Robin Linacre (creator) talks**: Multiple conference presentations on probabilistic linkage
