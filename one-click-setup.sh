ACCOUNT_ID=`aws sts get-caller-identity --query 'Account' --output text`

# get from env AWS_DEFAULT_REGION or aws config
REGION="${AWS_DEFAULT_REGION-$(aws configure get region)}"

# the IAM Role with sagemaker-full-access and s3 permission, 
# can be configured while creating SM notebook, or assumed by local IAM user
ROLE_NAME='sshhelper-for-sagemaker-role'
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# the IAM Policy with s3 permission
POLICY_NAME='sshhelper-for-sagemaker-policy'
MANAGED_SM_POLICY_ARN='arn:aws:iam::aws:policy/AmazonSageMakerFullAccess'
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

# used by sagemaker training job to assume this role(passed into estimator/role param)
# will add SSM permission by install-sshhelper, to registar job into SSM
SAGEMAKER_ROLE_ARN=$ROLE_ARN

# used by local IAM user to run ssh command, local user has to assume this role when ssh
# you can set to the IAM role/user ARN who need run ssh, or 
# add SSHSageMakerClientPolicy into user permission after this script finished
USER_ROLE_ARN=$ROLE_ARN

# the IAM Group that has permission to run ssh
IAM_USER_GROUP_NAME='SSHHelperUserGroup'
IAM_USER_GROUP_ARN="arn:aws:iam::$ACCOUNT_ID:group/$IAM_USER_GROUP_NAME"

action=$1

main() {
    case $action in
        add-user)
            add_user_to_group
            exit
            ;;
    esac
    check_if_role_exists
    install_sshhelper
    config_iam_group
}

config_iam_group() {
    # create IAM group
    aws iam create-group --group-name $IAM_USER_GROUP_NAME --output text

    # attach IAM Policy into group
    aws iam attach-group-policy --group-name $IAM_USER_GROUP_NAME --policy-arn $POLICY_ARN
    aws iam attach-group-policy --group-name $IAM_USER_GROUP_NAME --policy-arn $MANAGED_SM_POLICY_ARN
    aws iam attach-group-policy --group-name $IAM_USER_GROUP_NAME --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/SSHSageMakerClientPolicy"
}

add_user_to_group() {
    # list iam users, and parse into array
    resp=`aws iam list-users --query 'Users[*].[UserName]' --output text`
    while IFS= read -r line; do
        iam_users+=("$line")
    done <<< "$resp"

    length=${#iam_users[@]}

    echo "Choose the user you want to add into group $IAM_USER_GROUP_NAME:"
    for (( i=0; i<$length; i++ )); do
        echo "$i) ${iam_users[$i]}" 
    done

    echo -n "User index: "
    read user_idx
    user_name=${iam_users[$user_idx]}
    if [ ! -z $user_name ]; then
        # add user to group
        aws iam add-user-to-group --user-name $user_name --group-name $IAM_USER_GROUP_NAME
        echo "user $user_name added to group $IAM_USER_GROUP_NAME"
    else
        echo "invalid user index"
    fi
}

install_sshhelper() {
    pip install 'sagemaker-ssh-helper[cdk]'

    cdk bootstrap aws://"$ACCOUNT_ID"/"$REGION"

    APP="python -m sagemaker_ssh_helper.cdk.iam_ssm_app"

    AWS_REGION="$REGION" cdk -a "$APP" deploy SSH-IAM-SSM-Stack \
    -c sagemaker_role="$SAGEMAKER_ROLE_ARN" \
    -c user_role="$USER_ROLE_ARN"

    APP="python -m sagemaker_ssh_helper.cdk.advanced_tier_app"

    AWS_REGION="$REGION" cdk -a "$APP" deploy SSM-Advanced-Tier-Stack
}

check_if_role_exists() {
    # check if the role sshhelper-for-sagemaker-role exists
    resp=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text 2> /dev/null)

    # if last command success and $resp not equal to []
    if [[ $? -eq 0 && ! -z $resp ]]; then
        echo "The role $ROLE_NAME exists, skip creating."

        # echo -n "The role $ROLE_NAME exists. Do you want to delete it? (y/n): "
        # read delete_role
        # if [ $delete_role == 'y' ]; then
        #     # detach the policy from the role
        #     aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN 2> /dev/null
        #     aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $MANAGED_SM_POLICY_ARN 2> /dev/null
        #     aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/SSHSageMakerClientPolicy" 2> /dev/null
        #     aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/SSHSageMakerServerPolicy" 2> /dev/null
        #     # delete the role
        #     aws iam delete-role --role-name $ROLE_NAME
        #     # delete the policy
        #     aws iam delete-policy --policy-arn $POLICY_ARN 2> /dev/null

        #     echo role and policy deleted, will exit.
        #     exit
        # fi
    else
        create_iam_role
    fi
}

create_iam_role() {
    echo "creating the role $ROLE_NAME ..."
    cat <<EOF > /tmp/sshhelper-custom-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*"
            ]
        },
        {
            "Sid": "KMS",
            "Effect": "Allow",
            "Action": [
                "kms:GenerateDataKey",
                "kms:Decrypt"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Sid": "SSM",
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF

    # create IAM policy used by sagemaker training job
    echo creating the $POLICY_NAME policy ...
    resp=$(aws iam create-policy --policy-name $POLICY_NAME --policy-document file:///tmp/sshhelper-custom-policy.json)

    # allow sagemaker to assume the sshhelper-for-sagemaker-role
    cat <<EOF > /tmp/trust-sagemaker-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "sagemaker.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # create a IAM role using aws cli
    resp=`aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file:///tmp/trust-sagemaker-policy.json`

    # attach the sshhelper-for-sagemaker-policy to the sshhelper-for-sagemaker-role
    echo attaching the $POLICY_NAME policy
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN

    # attach the AmazonSageMakerFullAccess policy
    echo attaching the AmazonSageMakerFullAccess policy
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $MANAGED_SM_POLICY_ARN
}

get_identity_type() {
    type=`aws sts get-caller-identity --query 'Arn' | cut -f '6' -d ':' | cut -f '1' -d '/'`

    # when type equals to assumed-role
    if [ $type == 'assumed-role' ]; then
        return 0
    elif [ $type == 'user' ]; then
        return 1
    fi
}

main