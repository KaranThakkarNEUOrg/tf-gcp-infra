# Terraform Installation commands(reference[https://developer.hashicorp.com/terraform/install])

# Setup Terraform project

Add variables.tfvars file with the following content

```
project_id            = "<project_id>"
region                = "<region>"
credentials_file_path = "<json_file_name_from_glcoud>"
```

Run the following commands

```
terraform init
terraform validate
terraform fmt -check
terraform plan
terraform apply
terraform destroy
```

# Custom variables for the terraform setup

```
terraform apply -var 'project_id=YOUR_PROJECT_ID' -var 'region=YOUR_REGION' -var 'credentials_file_path=PATH_TO_YOUR_CREDENTIALS_FILE'
```

# Glcloud Installation

https://cloud.google.com/sdk/docs/install

# Gcloud auth login

This command will get the credentials from the gcloud and store it in the default location
Use this credentials file path in the terraform apply command

```
gcloud auth application-default login
```
