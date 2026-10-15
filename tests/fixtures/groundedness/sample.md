# 1.1 Title

## Intro

A StorageClass names the provisioner that creates the volume. It is **cluster-scoped** and never namespaced.
Short line here.

- `reclaimPolicy: Retain` keeps the volume after the claim is deleted.
- tiny item

| a | b |
|---|---|
| A table row is not a claim at all | x |

```yaml
kind: StorageClass  # code is never a claim, however many words it has
```

> See [the docs](https://example.org/x) for every field of the object.

## References

- Storage Classes, the official documentation page: https://kubernetes.io/docs/concepts/storage/storage-classes/
