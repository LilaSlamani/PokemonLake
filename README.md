# PokemonLake — TP Data Lake / Lakehouse

Architecture Data Lake basée sur **MinIO** (stockage objet), **PostgreSQL** (métadonnées) et **n8n** (orchestration), avec un workflow d'ingestion automatisé depuis la PokéAPI.

---

## Architecture

```
PokéAPI
   │
   ▼
n8n Workflow
   ├──► MinIO (raw-pokemon)       ← fichier JSON brut stocké comme objet
   └──► PostgreSQL (pokemon_lake) ← métadonnées + journal d'ingestion
```

| Couche | Technologie | Rôle |
|---|---|---|
| Stockage objet | MinIO | Conserver les fichiers bruts (JSON, images, rapports) |
| Base de métadonnées | PostgreSQL 16 | Référencer les fichiers et tracer les ingestions |
| Orchestration | n8n | Automatiser le pipeline d'ingestion |

---

## Prérequis

- Docker Desktop installé et démarré

---

## Structure du projet

```
PokemonLake/
├── docker-compose.yaml          # Définition des 4 services Docker
├── .env                         # Variables d'environnement (credentials)
├── init-db/
│   └── schema.sql               # Schéma PostgreSQL (chargé au premier boot)
└── workflows/
    └── pokemon_ingestion.json   # Workflow n8n importable
```

---

## Lancement et vérification

### Étape 1 — Démarrer l'environnement

```bash
docker compose up -d
```

Vérifier que tous les conteneurs sont bien démarrés :

```bash
docker compose ps
```

Résultat attendu :

```
NAME                   STATUS
postgres-pokemon       Up (healthy)
minio-pokemon          Up (healthy)
minio-pokemon-init     Exited (0)        ← normal, tourne une fois puis s'arrête
n8n-pokemon            Up
```

### Étape 2 — Vérifier MinIO

Ouvrir http://localhost:9003 et se connecter avec `pokemon_admin` / `pokemon_secret_2024`.

Dans le menu **Buckets**, les 3 buckets doivent être présents :
- `raw-pokemon`
- `pokemon-images`
- `reports`

Si les buckets sont absents, relancer manuellement l'init :

```bash
docker compose run --rm minio-pokemon-init
```

### Étape 3 — Vérifier PostgreSQL

Vérifier que le schéma a bien été chargé :

```bash
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "\dt"
```

Résultat attendu :
```
         List of relations
 Schema |       Name        | Type
--------+-------------------+-------
 public | file_ingestion_log| table
 public | pokemon_files     | table
```

### Étape 4 — Configurer et lancer le workflow n8n

1. Ouvrir http://localhost:5678
2. **Workflows → Import from file** → sélectionner `workflows/pokemon_ingestion.json`
3. Créer le credential PostgreSQL (voir section [Partie C](#partie-c--workflow-n8n))
4. Dans chaque nœud PostgreSQL du workflow, assigner ce credential
5. Dans le nœud **MinIO — Upload JSON**, passer l'authentification à **None**
6. Cliquer sur **Test workflow**

Tous les nœuds doivent passer au vert 

### Étape 5 — Vérifier les données en base

```bash
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "SELECT * FROM pokemon_files;"
```

```bash
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "SELECT * FROM file_ingestion_log;"
```

### Étape 6 — Vérifier le fichier dans MinIO

Ouvrir http://localhost:9003 → bucket `raw-pokemon` → dossier `bulbasaur/` → le fichier `bulbasaur_YYYY-MM-DD.json` doit être présent.

---

## Services et ports

| Service | URL | Credentials |
|---|---|---|
| MinIO Console | http://localhost:9003 | `pokemon_admin` / `pokemon_secret_2024` |
| MinIO API S3 | http://localhost:9002 | — |
| n8n | http://localhost:5678 | — |
| PostgreSQL | `localhost:5434` | `pokemon_user` / `pokemon_pass_2024` / `pokemon_lake` |

---

## Partie A — Organisation du stockage MinIO

Trois buckets sont créés automatiquement au démarrage :

| Bucket | Contenu |
|---|---|
| `raw-pokemon` | Réponses JSON brutes issues de la PokéAPI |
| `pokemon-images` | Images officielles et sprites des Pokémon |
| `reports` | Rapports CSV ou JSON générés |

**Choix retenu : plusieurs buckets distincts**, un par type de données. Cette organisation facilite la gestion des politiques d'accès et la séparation des responsabilités entre données brutes, médias et rapports.

---

## Partie B — Schéma de base enrichie

### `pokemon_files`
Catalogue de tous les fichiers stockés dans MinIO, liés à un Pokémon.

| Colonne | Type | Description |
|---|---|---|
| `file_id` | SERIAL PK | Identifiant unique |
| `pokemon_id` | INTEGER | ID du Pokémon (PokéAPI) |
| `bucket_name` | VARCHAR | Nom du bucket MinIO |
| `object_key` | VARCHAR | Chemin de l'objet dans le bucket |
| `file_name` | VARCHAR | Nom du fichier |
| `file_type` | VARCHAR | Extension (json, png, csv…) |
| `created_at` | TIMESTAMPTZ | Date de référencement |
| `file_size_bytes` | BIGINT | Taille en octets |
| `mime_type` | VARCHAR | Type MIME |
| `internal_url` | TEXT | URL S3 interne (réseau Docker) |
| `checksum` | VARCHAR | SHA-256 pour vérification d'intégrité |

### `file_ingestion_log`
Journal de toutes les tentatives d'ingestion (succès et erreurs).

| Colonne | Type | Description |
|---|---|---|
| `log_id` | SERIAL PK | Identifiant unique |
| `file_name` | VARCHAR | Nom du fichier ingéré |
| `bucket_name` | VARCHAR | Bucket cible |
| `object_key` | VARCHAR | Chemin dans le bucket |
| `processed_at` | TIMESTAMPTZ | Date de traitement |
| `source` | VARCHAR | Origine (pokeapi, manual…) |
| `status` | VARCHAR | `success`, `error` ou `pending` |
| `error_message` | TEXT | Message d'erreur si échec |
| `file_size_bytes` | BIGINT | Taille ingérée |

---

## Partie C — Workflow n8n

### Import

1. Ouvrir n8n → http://localhost:5678
2. **Workflows → Import from file** → sélectionner `workflows/pokemon_ingestion.json`

### Credentials à créer dans n8n

**PostgreSQL** (Settings → Credentials → New → PostgreSQL) :
```
Host     : postgres-pokemon
Port     : 5432
Database : pokemon_lake
User     : pokemon_user
Password : pokemon_pass_2024
```

### Étapes du workflow

```
Déclenchement Manuel
       │
       ▼
PokéAPI — GET /pokemon/bulbasaur
       │
       ▼
Préparation Fichier et Métadonnées   ← Code node : nom de fichier, object key, taille
       │
       ▼
MinIO — Upload JSON (raw-pokemon)    ← PUT http://minio-pokemon:9000/raw-pokemon/bulbasaur/...
       │
       ├──(succès)──►  PostgreSQL — INSERT pokemon_files
       │                      │
       │                      ▼
       │               PostgreSQL — INSERT log (succès)
       │
       └──(erreur)──►  PostgreSQL — INSERT log (erreur)
```

### Objet produit

```
raw-pokemon/
└── bulbasaur/
    └── bulbasaur_2026-06-18.json   (425.9 KiB — réponse brute PokéAPI)
```

---

## Partie D — Pourquoi cette architecture est un Data Lake / Lakehouse

L'architecture obtenue dépasse la logique d'une simple base relationnelle car elle repose sur une séparation explicite entre le stockage des fichiers et le stockage des métadonnées. MinIO apporte une vraie couche de stockage objet complémentaire : il conserve les fichiers bruts dans leur format d'origine (JSON, PNG, CSV), sans transformation, ce qui permet de les rejouer ou de les retraiter à tout moment sans dépendre à nouveau d'une API externe. La base PostgreSQL, elle, ne contient pas les fichiers — elle contient uniquement leurs métadonnées et un pointeur (`object_key`) vers l'objet dans le bucket. Ce découplage est fondamental : stocker des fichiers binaires en base relationnelle serait coûteux, non scalable, et inadapté à des formats hétérogènes. La table `file_ingestion_log` ajoute une traçabilité complète de tous les flux entrants (source, statut, date, erreur éventuelle), ce qui rapproche le projet d'une logique Lakehouse : on sait quoi a été ingéré, quand, et avec quel résultat. Une simple base relationnelle ne pourrait offrir ni le stockage fichier à faible coût, ni cette séparation des responsabilités entre brut et structuré.

---

## Commandes utiles

```bash
# Démarrer l'environnement
docker compose up -d

# Vérifier l'état des conteneurs
docker compose ps

# Suivre les logs en temps réel
docker compose logs -f n8n-pokemon
docker compose logs -f minio-pokemon
docker compose logs -f postgres-pokemon

# Vérifier les tables PostgreSQL
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "\dt"

# Consulter les fichiers ingérés
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "SELECT * FROM pokemon_files;"

# Consulter le journal d'ingestion
docker exec -it postgres-pokemon psql -U pokemon_user -d pokemon_lake -c "SELECT * FROM file_ingestion_log;"

# Arrêter l'environnement (conserve les données)
docker compose down

# Arrêter et supprimer les volumes (repart de zéro)
docker compose down -v
```
