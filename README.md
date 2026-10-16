# TP GitOps — Continuous Deployment avec Argo CD

Ce dépôt contient une démonstration complète et reproductible du modèle GitOps avec une application NGINX. Le dépôt Git est la **source unique de vérité** : Argo CD lit `apps/nginx/overlays/dev` et réconcilie automatiquement le cluster.

## Architecture

```text
Commit Git -> Argo CD (pull) -> Kubernetes
                 |                  |
                 +-- sync status   +-- health status
                 +-- self-healing
```

- **Application** : NGINX, 2 replicas, Service `ClusterIP`.
- **Packaging** : Kustomize (base + overlay `dev`).
- **CD** : Application Argo CD avec `automated`, `selfHeal` et `prune`.
- **Namespace cible** : `gitops-demo`.

## Pré-requis

- Un cluster Kubernetes accessible avec `kubectl` (kind, minikube, k3d ou cluster distant).
- `kubectl`, `git` et `kustomize` (ou une version de `kubectl` incluant `kubectl kustomize`).
- Un dépôt Git distant public, ou une configuration de credentials Argo CD pour un dépôt privé.

## 1. Installer Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \\
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment/argocd-server \\
  -n argocd --timeout=180s
```

Installer ensuite la CLI Argo CD selon la documentation officielle, puis ouvrir l'interface :

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Dans un autre terminal :

```bash
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
```

Le mot de passe initial doit être changé après la première connexion.

## 2. Publier le dépôt et créer l'Application

Remplacer `REPLACE_ME/gitops-nginx` dans [argocd/application.yaml](argocd/application.yaml) par l'URL réelle du dépôt, puis pousser le code :

```bash
git init
git add .
git commit -m "feat: initial gitops nginx application"
git branch -M main
git remote add origin https://github.com/<organisation>/<depot>.git
git push -u origin main
```

Déployer la déclaration Argo CD :

```bash
kubectl apply -f argocd/namespace.yaml
kubectl apply -f argocd/application.yaml
```

Vérifier l'état :

```bash
argocd app get nginx-gitops
kubectl -n gitops-demo get deploy,pods,svc
```

L'option `automated` signifie qu'aucun `argocd app sync` n'est nécessaire après un commit. `selfHeal: true` demande à Argo CD de corriger les modifications manuelles. `prune: true` supprime les ressources retirées de Git.

## 3. Démonstration obligatoire

### Scénario A — Continuous Deployment

Modifier le nombre de replicas dans [apps/nginx/base/deployment.yaml](apps/nginx/base/deployment.yaml), par exemple `2` vers `3` :

```bash
sed -i 's/replicas: 2/replicas: 3/' apps/nginx/base/deployment.yaml
git add . && git commit -m "feat: scale nginx to three replicas"
git push
```

Dans l'UI Argo CD, ouvrir `nginx-gitops`, afficher l'arbre des ressources et attendre le passage de `OutOfSync` à `Synced`. Dans le terminal :

```bash
kubectl -n gitops-demo get deploy nginx -w
```

Le changement est tiré par Argo CD ; aucun accès de déploiement externe au cluster n'est utilisé.

### Scénario B — Drift et self-healing

Supprimer une ressource directement dans le cluster :

```bash
kubectl -n gitops-demo delete deployment nginx
kubectl -n gitops-demo get deployment nginx -w
```

L'UI doit afficher temporairement un écart et Argo CD doit recréer le Deployment grâce à `selfHeal: true`. La source de vérité reste le dépôt : ne pas committer cette suppression.

Pour rendre le drift plus visible pendant la présentation, suspendre temporairement l'auto-sync depuis l'UI, supprimer le Deployment, montrer `Missing/OutOfSync`, puis réactiver l'auto-sync et observer la réparation.

### Scénario C — Sync status contre Health status

Introduire volontairement une erreur dans Git en remplaçant l'image par une image inexistante :

```bash
sed -i 's#nginx:1.27-alpine#nginx:does-not-exist#' apps/nginx/base/deployment.yaml
git add . && git commit -m "test: introduce invalid image"
git push
```

Résultat attendu dans Argo CD :

- **Sync: Synced** : le manifeste déployé correspond bien à Git.
- **Health: Degraded** ou `Progressing` : les Pods ne démarrent pas.
- `kubectl -n gitops-demo describe pod <pod>` montre `ErrImagePull` ou `ImagePullBackOff`.

Cette distinction est essentielle : une déclaration peut être synchronisée tout en décrivant une application non opérationnelle.

### Scénario D — Historique et rollback

1. Ouvrir `nginx-gitops` dans Argo CD.
2. Ouvrir **History and Rollback**.
3. Sélectionner la version stable précédente et choisir **Rollback**.
4. Vérifier que les Pods reviennent à l'état `Healthy`.

Avec l'auto-sync activé, Git reste la source de vérité : Argo CD peut réappliquer l'état erroné du dernier commit. Pour une démonstration stable, désactiver temporairement l'auto-sync avant le rollback, ou corriger Git immédiatement après :

```bash
sed -i 's#nginx:does-not-exist#nginx:1.27-alpine#' apps/nginx/base/deployment.yaml
git add . && git commit -m "fix: restore stable nginx image"
git push
```

La correction Git est la solution durable ; le rollback UI démontre la capacité de retour rapide et l'historique des révisions.

## Vérifications utiles

```bash
# Valider le rendu Kustomize localement
./scripts/render.sh > /tmp/nginx-rendered.yaml
kubectl apply --dry-run=client -f /tmp/nginx-rendered.yaml

# Voir les événements et l'état réel des Pods
kubectl -n gitops-demo get all
kubectl -n gitops-demo get events --sort-by=.lastTimestamp

# Consulter l'état Argo CD
argocd app get nginx-gitops
argocd app history nginx-gitops
```

## Critères couverts

| Critère | Implémentation |
|---|---|
| SSOT | Manifests Kustomize versionnés dans Git |
| Pull-based CD | Argo CD observe `repoURL` et applique les changements |
| Drift / self-healing | `automated.selfHeal: true` |
| Nettoyage | `automated.prune: true` |
| Sync vs Health | Erreur d'image volontaire du scénario C |
| Historique / rollback | Révisions Argo CD et scénario D |
