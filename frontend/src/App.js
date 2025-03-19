import { Amplify, Auth, API, Storage } from 'aws-amplify';
import { useState } from 'react';
import { withAuthenticator } from '@aws-amplify/ui-react';
import awsconfig from './amplify-config';

Amplify.configure(awsconfig);

function App() {
  const [messages, setMessages] = useState([]);
  const [query, setQuery] = useState('');
  const [file, setFile] = useState(null);
  const [recording, setRecording] = useState(false);
  const [mediaRecorder, setMediaRecorder] = useState(null);

  const sendMessage = async () => {
    const response = await API.post('ChatApi', '/chat', { body: { query, to_speech: true } });
    setMessages([...messages, { role: 'user', content: query }, { role: 'bot', content: response.text }]);
    if (response.audio) new Audio(`data:audio/mp3;base64,${response.audio}`).play();
    setQuery('');
  };

  const uploadFile = async () => {
    const { key } = await Storage.put(file.name, file);
    await API.post('ChatApi', '/chat', { body: { s3_upload: key } });
    alert('File uploaded and processed');
    setFile(null);
  };

  const startRecording = async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const recorder = new MediaRecorder(stream);
    setMediaRecorder(recorder);
    recorder.start();
    setRecording(true);
    const chunks = [];
    recorder.ondataavailable = (e) => chunks.push(e.data);
    recorder.onstop = async () => {
      const blob = new Blob(chunks, { type: 'audio/wav' });
      const reader = new FileReader();
      reader.onloadend = async () => {
        const audioData = reader.result.split(',')[1]; // Base64
        const response = await API.post('ChatApi', '/chat', { body: { audio: audioData } });
        setQuery(response.text);
      };
      reader.readAsDataURL(blob);
    };
  };

  const stopRecording = () => {
    mediaRecorder.stop();
    mediaRecorder.stream.getTracks().forEach(track => track.stop());
    setRecording(false);
  };

  return (
    <div style={{ padding: '20px' }}>
      <h1>Chatbot</h1>
      <div style={{ border: '1px solid #ccc', padding: '10px', maxHeight: '300px', overflowY: 'auto' }}>
        {messages.map((m, i) => (
          <p key={i}><strong>{m.role}:</strong> {m.content}</p>
        ))}
      </div>
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        style={{ width: '300px', margin: '10px 0' }}
      />
      <button onClick={sendMessage}>Send</button>
      <div>
        <button onClick={startRecording} disabled={recording}>Start Recording</button>
        <button onClick={stopRecording} disabled={!recording}>Stop Recording</button>
      </div>
      <input type="file" onChange={(e) => setFile(e.target.files[0])} style={{ margin: '10px 0' }} />
      <button onClick={uploadFile} disabled={!file}>Upload</button>
      <button onClick={() => Auth.signOut()} style={{ marginLeft: '10px' }}>Sign Out</button>
    </div>
  );
}

export default withAuthenticator(App);