import time
import os
import sagemaker_ssh_helper

# MUST: init sagemaker-ssh-helper
sagemaker_ssh_helper.setup_and_start_ssh()


# option 1, sleep for ever, and then you SSH into this container and run your training job manually.
time.sleep(1000000)

# # option 2, you can run your code intead of time.sleep, 
# # but in this case, you can not stop the training process, otherwise the training job will stop

# os.system('python /app/main.py')