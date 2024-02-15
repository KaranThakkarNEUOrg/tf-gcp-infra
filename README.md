# Terraform setup commands(reference[https://developer.hashicorp.com/terraform/install])

```
terraform init
terraform validate
terraform plan
terraform apply
terraform destroy
```

# Custom variables for the terraform setup

```
terraform apply -var 'project_id=YOUR_PROJECT_ID' -var 'region=YOUR_REGION' -var 'credentials_file_path=PATH_TO_YOUR_CREDENTIALS_FILE'
```

# Gcloud auth login

```
gcloud auth application-default login
```
