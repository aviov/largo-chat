const awsconfig = {
    Auth: {
      region: 'eu-central-1', // Update to your region
      userPoolId: 'eu-central-1_vuBhAGI2h', // From CDK output
      userPoolWebClientId: '2v3eiooib760odbkcgg949op8j', // From CDK output
    },
    API: {
      endpoints: [
        {
          name: 'ChatApi',
          endpoint: 'https://z159wnpazl.execute-api.eu-central-1.amazonaws.com/prod/', // From CDK output
          custom_header: async () => ({
            Authorization: `Bearer ${(await Auth.currentSession()).getIdToken().getJwtToken()}`,
          }),
        },
      ],
    },
    Storage: {
      AWSS3: {
        bucket: 'chatbotstack-contentbucket52d4b12c-3nzaezgr3s7l', // From CDK output or AWS Console
        region: 'eu-central-1', // Update to your region
      },
    },
  };
  
  export default awsconfig;